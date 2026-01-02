#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "kubectl" "helm" "jq"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CENTRAL=${CENTRAL:-lgtm-central}
CERT_ISSUER_ID=${CERT_ISSUER_ID:-issuer-otel}
CONTEXT=${CONTEXT:-lgtm-remote-otel}
SUBNET=${SUBNET:-232} # Last octet from the /29 CIDR subnet to use for LoadBalancer IPs
WORKERS=${WORKERS:-1}
CLUSTER_ID=${CLUSTER_ID:-3} # Unique on each cluster
POD_CIDR=${POD_CIDR:-10.31.0.0/16} # Unique on each cluster
SVC_CIDR=${SVC_CIDR:-10.32.0.0/16} # Unique on each cluster
CILIUM_CLUSTER_MESH_ENABLED=${CILIUM_CLUSTER_MESH_ENABLED:-no} # no for Linkerd or Istio, yes for Cilium CM
ISTIO_ENABLED=${ISTIO_ENABLED:-no} # no for Linkerd, yes for Istio
APP_NS="otel" # Used by deploy-mesh.sh

echo "Deploying Kubernetes"
. deploy-kind.sh

echo "Deploying Prometheus CRDs (for ServiceMonitor/PodMonitor support)"
helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds

echo "Deploying cert-manager (required by OpenTelemetry Operator)"
helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace -f values-certmanager.yaml --wait

echo "Deploying OpenTelemetry Operator (for Target Allocator)"
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator -n observability --create-namespace --wait
kubectl apply -f otelcol-rbac.yaml

echo "Deploying Mesh"
FILES=("otelcol-daemonset-cr.yaml" "otelcol-deployment-cr.yaml")
. deploy-mesh.sh

echo "Deploying OpenTelemetry Collector DaemonSet (for logs and node metrics)"
kubectl apply -f /tmp/otelcol-daemonset-cr.yaml

echo "Deploying OpenTelemetry Collector StatefulSet (with Target Allocator for ServiceMonitor/PodMonitor)"
kubectl apply -f /tmp/otelcol-deployment-cr.yaml

echo "Deploying OpenTelemetry Demo application"
helm upgrade --install demo open-telemetry/opentelemetry-demo -n ${APP_NS} -f values-opentelemetry-demo.yaml
