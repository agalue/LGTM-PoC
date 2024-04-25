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
SUBNET=${SUBNET-240} # For Cilium L2/LB (must be unique across all clusters)
WORKERS=${WORKERS-1}
CLUSTER_ID=${CLUSTER_ID-2} # Unique on each cluster
POD_CIDR=${POD_CIDR-10.21.0.0/16} # Unique on each cluster
SVC_CIDR=${SVC_CIDR-10.22.0.0/16} # Unique on each cluster
CILIUM_CLUSTER_MESH_ENABLED=${CILIUM_CLUSTER_MESH_ENABLED-no}
APP_NS="tns"

echo "Deploying Kubernetes"
. deploy-kind.sh

echo "Deploying Prometheus CRDs"
helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds

FILES=("grafana-remote-config.alloy" "values-prometheus-remote.yaml" "values-promtail-remote.yaml")
cp "${FILES[@]}" /tmp
if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" == "yes" ]]; then
  for FILE in "${FILES[@]}"; do
    sed "s/-${CENTRAL}//" "${FILE}" > "/tmp/${FILE}"
  done
else
  echo "Deploying Linkerd"
  . deploy-linkerd.sh
fi

echo "Connect to Central"
. deploy-link.sh

echo "Deploying Prometheus (for Metrics)"
helm upgrade --install monitor prometheus-community/kube-prometheus-stack \
  -n observability -f values-prometheus-common.yaml -f /tmp/values-prometheus-remote.yaml \
  --set prometheusOperator.clusterDomain=$DOMAIN --wait

echo "Deploying Grafana Promtail (for Logs)"
helm upgrade --install promtail grafana/promtail \
  -n observability -f values-promtail-common.yaml -f /tmp/values-promtail-remote.yaml --wait

echo "Deplyoing Grafana Alloy (for Traces)"
helm upgrade --install alloy -n observability grafana/alloy \
  -f values-alloy.yaml \
  --set-file alloy.configMap.content=/tmp/grafana-remote-config.alloy \
  --wait

echo "Deploying Grafana TNS application"
kubectl apply -n ${APP_NS} -f grafana-tns-apps.yaml
