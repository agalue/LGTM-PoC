#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "kubectl" "helm" "linkerd" "jq"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CENTRAL=${CENTRAL-lgtm-central}
CERT_ISSUER_ID=${CERT_ISSUER_ID-issuer-otel}
CONTEXT=${CONTEXT-lgtm-remote-otel}
DOMAIN=${DOMAIN-${CONTEXT}.cluster.local}
SUBNET=${SUBNET-240} # For Cilium L2/LB
WORKERS=${WORKERS-1}
CLUSTER_ID=${CLUSTER_ID-3}
POD_CIDR=${POD_CIDR-10.31.0.0/16}
SVC_CIDR=${SVC_CIDR-10.32.0.0/16}
CILIUM_CLUSTER_MESH_ENABLED=${CILIUM_CLUSTER_MESH_ENABLED-no}
LINKERD_JAEGER_ENABLED=no # Linkerd Jaeger doesn't support OTLP
APP_NS="otel"

echo "Deploying Kubernetes"
. deploy-kind.sh

echo "Deploying Prometheus CRDs"
helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds

if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" != "yes" ]]; then
  echo "Deploying Linkerd"
  . deploy-linkerd.sh
fi

echo "Connect to Central"
. deploy-link.sh

echo "Deploying Prometheus (for local Kubernetes Metrics)"
helm upgrade --install monitor prometheus-community/kube-prometheus-stack \
  -n observability -f values-prometheus-common.yaml -f values-prometheus-remote-otel.yaml \
  --set prometheusOperator.clusterDomain=$DOMAIN --wait

echo "Deploying OpenTelemetry Demo application"
helm upgrade --install demo open-telemetry/opentelemetry-demo \
  -n ${APP_NS} -f values-opentelemetry-demo.yaml
kubectl rollout status -n otel deployment/demo-otelcol
