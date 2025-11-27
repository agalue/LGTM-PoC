#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "kubectl" "helm"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CERT_ISSUER_ID=${CERT_ISSUER_ID-issuer-central}
CONTEXT=${CONTEXT-lgtm-central}
SUBNET=${SUBNET-248} # Last octet from the /29 CIDR subnet to use for LoadBalancer IPs
WORKERS=${WORKERS-3}
CLUSTER_ID=${CLUSTER_ID-1} # Unique on each cluster
POD_CIDR=${POD_CIDR-10.11.0.0/16} # Unique on each cluster
SVC_CIDR=${SVC_CIDR-10.12.0.0/16} # Unique on each cluster
SERVICE_MESH_HA=${SERVICE_MESH_HA-yes}
CILIUM_CLUSTER_MESH_ENABLED=${CILIUM_CLUSTER_MESH_ENABLED-no} # no for Linkerd or Istio, yes for Cilium CM
ISTIO_ENABLED=${ISTIO_ENABLED-no} # no for Linkerd, yes for Istio
ISTIO_PROFILE=${ISTIO_PROFILE-default} # default or ambient

echo "Updating Helm Repositories"
helm repo add jetstack https://charts.jetstack.io
helm repo add linkerd https://helm.linkerd.io/stable
helm repo add linkerd-edge https://helm.linkerd.io/edge
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add vector https://helm.vector.dev
helm repo add minio https://charts.min.io/
helm repo add metallb https://metallb.github.io/metallb
helm repo update &> /dev/null

echo "Deploying Kubernetes"
. deploy-kind.sh

echo "Deploying Prometheus CRDs"
helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds

echo "Deploying Cert-Manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  -f values-certmanager.yaml --wait

if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" != "yes" ]]; then
  if [[ "${ISTIO_ENABLED}" == "yes" ]]; then
    echo "Deploying Istio"
    . deploy-istio.sh
  else
    echo "Deploying Linkerd"
    . deploy-linkerd.sh
  fi
fi

echo "Setting up namespaces"
ISTIO_LABEL="istio-injection: enabled"
if [[ "$ISTIO_PROFILE" == "ambient" ]]; then
  ISTIO_LABEL="istio.io/dataplane-mode: ambient"
fi
for ns in observability storage tempo loki mimir; do
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    $ISTIO_LABEL
EOF
done

echo "Deploying Prometheus (for Local Metrics)"
helm upgrade --install monitor prometheus-community/kube-prometheus-stack \
  -n observability -f values-prometheus-common.yaml -f values-prometheus-central.yaml --wait

echo "Deploying MinIO for Loki, Tempo and Mimir"
helm upgrade --install minio minio/minio \
  -n storage -f values-minio.yaml --wait
kubectl rollout status -n storage deployment/minio

echo "Deploying Grafana Tempo"
helm upgrade --install tempo grafana/tempo-distributed \
  -n tempo -f values-tempo.yaml --wait

echo "Deploying Grafana Loki"
helm upgrade --install loki grafana/loki \
  -n loki -f values-loki.yaml --wait

echo "Deploying Vector (for Logs)"
helm upgrade --install vector vector/vector \
  -n observability -f values-vector-common.yaml -f values-vector-central.yaml --wait

echo "Deploying Grafana Alloy (for Traces)"
helm upgrade --install alloy -n observability grafana/alloy \
  -f values-alloy.yaml \
  --set-file alloy.configMap.content=grafana-central-config.alloy \
  --wait

echo "Deploying Grafana Mimir"
helm upgrade --install mimir grafana/mimir-distributed \
  -n mimir -f values-mimir.yaml
kubectl rollout status -n mimir deployment/mimir-distributor
kubectl rollout status -n mimir deployment/mimir-query-frontend

echo "Create Ingress resources (using Gateway API via Cilium)"
kubectl apply -f ingress-central.yaml

declare -a SERVICES=( \
  "service/mimir-distributor -n mimir" \
  "service/tempo-distributor -n tempo" \
  "service/loki-write -n loki" \
  "service/monitor-alertmanager -n observability"
)
if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" == "yes" ]]; then
  echo "Exporting Services via Cilium ClusterMesh"
  for SVC in "${SERVICES[@]}"; do
    kubectl annotate ${SVC} service.cilium.io/global=true --overwrite
    kubectl annotate ${SVC} service.cilium.io/shared=true --overwrite
  done
else
  if [[ "${ISTIO_ENABLED}" != "yes" ]]; then
    echo "Exporting Services via Linkerd Multicluster"
    for SVC in "${SERVICES[@]}"; do
      kubectl label ${SVC} mirror.linkerd.io/exported=true --overwrite
    done
  else
    if [[ "${ISTIO_PROFILE}" == "ambient" ]]; then
      echo "Exporting Services via Istio Ambient Multicluster"
      for SVC in "${SERVICES[@]}"; do
        kubectl label ${SVC} istio.io/global="true" --overwrite
      done
    fi
  fi
fi

# Update DNS
INGRESS_IP=$(kubectl get service -n observability cilium-gateway-lgtm-external-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Remember to append an entry for grafana.example.com pointing to $INGRESS_IP in /etc/hosts to test the Ingress resources"
