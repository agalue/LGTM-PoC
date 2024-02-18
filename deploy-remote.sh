#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "kubectl" "helm" "linkerd"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CERT_ISSUER_ID=${CERT_ISSUER_ID-issuer-remote}
CONTEXT=${CONTEXT-lgtm-remote}
DOMAIN=${DOMAIN-${CONTEXT}.cluster.local}
SUBNET=${SUBNET-240} # For Cilium L2/LB
WORKERS=${WORKERS-1}
WORKERS_CPUS=${WORKERS_CPUS-2}
WORKERS_MEMORY=${WORKERS_MEMORY-4}

# Empty /var/db/dhcpd_leases if you ran out of IP addresses on your Mac
echo "Deploying Kubernetes"
. deploy-kind.sh

echo "Deploying Prometheus CRDs"
. deploy-prometheus-crds.sh

echo "Deploying Linkerd"
. deploy-linkerd.sh

echo "Creating link from the remote cluster into the central cluster"
if [[ -e lgtm-central-kubeconfig.yaml && -e lgtm-remote-kubeconfig.yaml ]]; then
  export KUBECONFIG="lgtm-central-kubeconfig.yaml:lgtm-remote-kubeconfig.yaml"
  kubectl config use-context $CONTEXT
fi
# The following is required when using Kind/Docker without apiServerAddress on Kind config.
API_SERVER=$(kubectl get node --context lgtm-central -l node-role.kubernetes.io/control-plane -o json \
  | jq -r '.items[] | .status.addresses[] | select(.type=="InternalIP") | .address')
linkerd mc link --context lgtm-central --cluster-name lgtm-central \
  --api-server-address="https://${API_SERVER}:6443" \
  | kubectl apply --context lgtm-remote -f -

echo "Setting up namespaces"
for ns in observability tns mimir tempo loki; do
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
kubectl apply -f remote-agent-config-remote.yaml
kubectl apply -f remote-agent.yaml

echo "Deploying TNS application"
kubectl apply -f remote-apps.yaml
