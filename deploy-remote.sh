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
POD_CIDR=${POD_CIDR-10.3.0.0/16}
SVC_CIDR=${SVC_CIDR-10.4.0.0/16}

echo "Deploying Kubernetes"
. deploy-kind.sh

echo "Deploying Prometheus CRDs"
helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds

echo "Deploying Linkerd"
. deploy-linkerd.sh

CENTRAL_CTX=kind-${CENTRAL}
REMOTE_CTX=kind-${CONTEXT}

# The following is required when using Kind/Docker without apiServerAddress on Kind config.
API_SERVER=$(kubectl get node --context ${CENTRAL_CTX} -l node-role.kubernetes.io/control-plane -o json \
  | jq -r '.items[] | .status.addresses[] | select(.type=="InternalIP") | .address')

echo "Creating link from ${REMOTE_CTX} to ${CENTRAL_CTX}"
linkerd mc link --context ${CENTRAL_CTX} --cluster-name ${CENTRAL} \
  --api-server-address="https://${API_SERVER}:6443" \
  | kubectl apply --context ${REMOTE_CTX} -f -

echo "Setting up namespaces"
for ns in observability mimir tempo loki tns; do
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  annotations:
    linkerd.io/inject: enabled
EOF
done

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
kubectl apply -f grafana-tns-apps.yaml
