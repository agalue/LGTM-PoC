#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "kubectl" "helm" "linkerd" "jq"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CENTRAL=${CENTRAL-lgtm-central}
CERT_ISSUER_ID=${CERT_ISSUER_ID-issuer-remote}
CONTEXT=${CONTEXT-lgtm-remote}
DOMAIN=${DOMAIN-${CONTEXT}.cluster.local}
SUBNET=${SUBNET-240} # For Cilium L2/LB
WORKERS=${WORKERS-1}
CLUSTER_ID=${CLUSTER_ID-2}
POD_CIDR=${POD_CIDR-10.21.0.0/16}
SVC_CIDR=${SVC_CIDR-10.22.0.0/16}
CILIUM_CLUSTER_MESH_ENABLED=${CILIUM_CLUSTER_MESH_ENABLED-no}
APP_NS="tns"

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

echo "Deploying Prometheus (for Metrics)"
helm upgrade --install monitor prometheus-community/kube-prometheus-stack \
  -n observability -f values-prometheus-common.yaml -f values-prometheus-remote.yaml \
  --set prometheusOperator.clusterDomain=$DOMAIN --wait

echo "Deploying Grafana Promtail (for Logs)"
helm upgrade --install promtail grafana/promtail \
  -n observability -f values-promtail-common.yaml -f values-promtail-remote.yaml --wait

echo "Deplying Grafana Agent (for Traces)"
kubectl apply -f grafana-agent-config-remote.yaml
helm upgrade --install grafana-agent grafana/grafana-agent \
  -n observability -f values-agent.yaml --wait

echo "Deploying Grafana TNS application"
kubectl apply -n ${APP_NS} -f grafana-tns-apps.yaml
