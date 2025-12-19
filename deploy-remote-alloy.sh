#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "kubectl" "helm" "jq"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CENTRAL=${CENTRAL:-lgtm-central}
CERT_ISSUER_ID=${CERT_ISSUER_ID:-issuer-alloy}
CONTEXT=${CONTEXT:-lgtm-remote-alloy}
SUBNET=${SUBNET:-224} # Last octet from the /29 CIDR subnet to use for LoadBalancer IPs
WORKERS=${WORKERS:-1}
CLUSTER_ID=${CLUSTER_ID:-4} # Unique on each cluster (1=central, 2=remote, 3=remote-otel, 4=remote-alloy)
POD_CIDR=${POD_CIDR:-10.41.0.0/16} # Unique on each cluster
SVC_CIDR=${SVC_CIDR:-10.42.0.0/16} # Unique on each cluster
CILIUM_CLUSTER_MESH_ENABLED=${CILIUM_CLUSTER_MESH_ENABLED:-no} # no for Linkerd or Istio, yes for Cilium CM
ISTIO_ENABLED=${ISTIO_ENABLED:-no} # no for Linkerd, yes for Istio
APP_NS="tns"  # Used by deploy-mesh.sh

echo "Deploying Kubernetes"
. deploy-kind.sh

echo "Deploying Prometheus CRDs"
helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds

echo "Deploying Mesh"
FILES=("values-alloy-daemonset.yaml" "values-alloy-deployment.yaml")
. deploy-mesh.sh

echo "Deploying Grafana Alloy DaemonSet (for logs and node metrics)"
helm upgrade --install alloy-ds grafana/alloy \
  -n observability -f /tmp/values-alloy-daemonset.yaml --wait

echo "Deploying Grafana Alloy Deployment (for ServiceMonitors, PodMonitors, and traces)"
helm upgrade --install alloy grafana/alloy \
  -n observability -f /tmp/values-alloy-deployment.yaml --wait

echo "Deploying Grafana TNS application"
kubectl apply -n ${APP_NS} -f grafana-tns-apps.yaml
