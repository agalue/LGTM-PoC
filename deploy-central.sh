#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "kubectl" "helm"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CERT_ISSUER_ID=${CERT_ISSUER_ID-issuer-central}
CONTEXT=${CONTEXT-lgtm-central}
DOMAIN=${DOMAIN-${CONTEXT}.cluster.local}
SUBNET=${SUBNET-248} # For Cilium L2/LB
WORKERS=${WORKERS-3}
WORKERS_CPUS=${WORKERS_CPUS-2}
WORKERS_MEMORY=${WORKERS_MEMORY-4}
CLUSTER_ID=${CLUSTER_ID-1}
POD_CIDR=${POD_CIDR-10.1.0.0/16}
SVC_CIDR=${SVC_CIDR-10.2.0.0/16}
LINKERD_HA=${LINKERD_HA-yes}

echo "Updating Helm Repositories"
helm repo add jetstack https://charts.jetstack.io
helm repo add linkerd https://helm.linkerd.io/stable
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add minio https://charts.min.io/
helm repo update

# Empty /var/db/dhcpd_leases if you ran out of IP addresses on your Mac
echo "Deploying Kubernetes"
. deploy-k3s.sh

echo "Deploying Prometheus CRDs"
helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds

echo "Deploying Cert-Manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  -f values-certmanager.yaml --wait

echo "Deploying Linkerd"
. deploy-linkerd.sh

echo "Setting up namespaces"
for ns in observability storage tempo loki mimir; do
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  annotations:
    linkerd.io/inject: enabled
EOF
done

echo "Deploying Prometheus (for Local Metrics)"
helm upgrade --install monitor prometheus-community/kube-prometheus-stack \
  -n observability -f values-prometheus-common.yaml -f values-prometheus-central.yaml \
  --set prometheusOperator.clusterDomain=$DOMAIN --wait

echo "Deploying MinIO for Loki, Tempo and Mimir"
helm upgrade --install minio minio/minio \
  -n storage -f values-minio.yaml --wait

echo "Deploying Grafana Tempo"
helm upgrade --install tempo grafana/tempo-distributed \
  -n tempo -f values-tempo.yaml --set global.clusterDomain=$DOMAIN --wait

echo "Deploying Grafana Loki"
helm upgrade --install loki grafana/loki \
  -n loki -f values-loki.yaml --set global.clusterDomain=$DOMAIN --wait

echo "Deploying Grafana Promtail (for Logs)"
helm upgrade --install promtail grafana/promtail \
  -n observability -f values-promtail-common.yaml -f values-promtail-central.yaml --wait

echo "Deplying Grafana Agent (for Traces)"
kubectl apply -f grafana-agent-config-central.yaml
helm upgrade --install grafana-agent grafana/grafana-agent \
  -n observability -f values-agent.yaml --wait

echo "Deploying Grafana Mimir"
helm upgrade --install mimir grafana/mimir-distributed \
  -n mimir -f values-mimir.yaml --set global.clusterDomain=$DOMAIN
kubectl rollout status -n mimir deployment/mimir-distributor
kubectl rollout status -n mimir deployment/mimir-query-frontend

echo "Create Ingress resources"
kubectl apply -f ingress-central.yaml

echo "Deploying Nginx Ingress Controller"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace -f values-ingress.yaml --wait

echo "Exporting Services via Linkerd Multicluster"
kubectl -n tempo label service/tempo-distributor mirror.linkerd.io/exported=true
kubectl -n mimir label service/mimir-distributor mirror.linkerd.io/exported=true
kubectl -n loki label service/loki-write mirror.linkerd.io/exported=true
kubectl -n observability label service/monitor-alertmanager mirror.linkerd.io/exported=true

# Update DNS
INGRESS_IP=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Remember to append an entry for grafana.example.com pointing to $INGRESS_IP in /etc/hosts to test the Ingress resources"
