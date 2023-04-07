#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "minikube" "kubectl" "helm" "linkerd"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

DRIVER=${DRIVER-hyperkit}
DOMAIN=lgtm-central.cluster.local
CERT_ISSUER_ID=issuer-central

# Empty /var/db/dhcpd_leases if you ran out of IP addresses on your Mac
if minikube status --profile=lgtm-central > /dev/null; then
  echo "Minikube already running"
else
  echo "Starting minikube"
  minikube start \
    --driver=$DRIVER \
    --container-runtime=containerd \
    --cpus=4 \
    --memory=16g \
    --addons=metrics-server \
    --addons=metallb \
    --dns-domain=$DOMAIN \
    --embed-certs=true \
    --profile=lgtm-central
fi

MINIKUBE_IP=$(minikube ip -p lgtm-central)
expect <<EOF
spawn minikube addons configure metallb -p lgtm-central
expect "Enter Load Balancer Start IP:" { send "${MINIKUBE_IP%.*}.201\\r" }
expect "Enter Load Balancer End IP:" { send "${MINIKUBE_IP%.*}.210\\r" }
expect eof
EOF

echo "Updating Helm Repositories"
helm repo add jetstack https://charts.jetstack.io
helm repo add linkerd https://helm.linkerd.io/stable
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add minio https://charts.min.io/
helm repo update

echo "Deploying Prometheus CRDs"
. deploy-prometheus-crds.sh

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
  -n observability -f values-prometheus-common.yaml -f values-prometheus-central.yaml --wait

echo "Deploying MinIO for Loki, Tempo and Mimir"
helm upgrade --install minio minio/minio \
  -n storage -f values-minio.yaml --wait

echo "Deploying Grafana Tempo"
helm upgrade --install tempo grafana/tempo-distributed \
  -n tempo -f values-tempo.yaml --wait

echo "Deploying Grafana Loki"
helm upgrade --install loki grafana/loki \
  -n loki -f values-loki.yaml --wait

echo "Deploying Grafana Promtail (for Logs)"
helm upgrade --install promtail grafana/promtail \
  -n observability -f values-promtail-common.yaml -f values-promtail-central.yaml --wait

echo "Deplying Grafana Agent (for Traces)"
kubectl apply -f remote-agent-config-central.yaml
kubectl apply -f remote-agent.yaml

echo "Deploying Grafana Mimir"
helm upgrade --install mimir grafana/mimir-distributed \
  -n mimir -f values-mimir.yaml
kubectl rollout status -n mimir deploy/mimir-distributor
kubectl rollout status -n mimir deploy/mimir-query-frontend

echo "Deploying Nginx Ingress Controller"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace -f values-ingress.yaml

echo "Waiting for Nginx to be ready"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

echo "Create Ingress resources"
kubectl apply -f ingress-central.yaml

echo "Exporting Services via Linkerd Multicluster"
kubectl -n tempo label svc/tempo-distributor mirror.linkerd.io/exported=true
kubectl -n mimir label svc/mimir-distributor mirror.linkerd.io/exported=true
kubectl -n loki label svc/loki-write mirror.linkerd.io/exported=true

# Update DNS
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Remember to add entries to /etc/hosts pointing to $INGRESS_IP to test the Ingress resources"
