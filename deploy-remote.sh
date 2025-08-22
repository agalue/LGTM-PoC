#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "kubectl" "helm" "jq"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CENTRAL=${CENTRAL-lgtm-central}
CERT_ISSUER_ID=${CERT_ISSUER_ID-issuer-remote}
CONTEXT=${CONTEXT-lgtm-remote}
SUBNET=${SUBNET-240} # Last octet from the /29 CIDR subnet to use for LoadBalancer IPs
WORKERS=${WORKERS-1}
CLUSTER_ID=${CLUSTER_ID-2} # Unique on each cluster
POD_CIDR=${POD_CIDR-10.21.0.0/16} # Unique on each cluster
SVC_CIDR=${SVC_CIDR-10.22.0.0/16} # Unique on each cluster
CILIUM_CLUSTER_MESH_ENABLED=${CILIUM_CLUSTER_MESH_ENABLED-no} # no for Linkerd or Istio, yes for Cilium CM
ISTIO_ENABLED=${ISTIO_ENABLED-no} # no for Linkerd, yes for Istio
APP_NS="tns"  # Used by deploy-mesh.sh

echo "Deploying Kubernetes"
. deploy-kind.sh

echo "Deploying Prometheus CRDs"
helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds

echo "Deploying Mesh"
FILES=("grafana-remote-config.alloy" "values-prometheus-remote.yaml" "values-vector-remote.yaml")
. deploy-mesh.sh

echo "Deploying Prometheus (for Metrics)"
helm upgrade --install monitor prometheus-community/kube-prometheus-stack \
  -n observability -f values-prometheus-common.yaml -f /tmp/values-prometheus-remote.yaml --wait

echo "Deploying Vector (for Logs)"
helm upgrade --install vector vector/vector \
  -n observability -f values-vector-common.yaml -f /tmp/values-vector-remote.yaml --wait

echo "Deploying Grafana Alloy (for Traces)"
helm upgrade --install alloy -n observability grafana/alloy \
  -f values-alloy.yaml \
  --set-file alloy.configMap.content=/tmp/grafana-remote-config.alloy \
  --wait

echo "Deploying Grafana TNS application"
kubectl apply -n ${APP_NS} -f grafana-tns-apps.yaml
