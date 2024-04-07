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
WORKERS_CPUS=${WORKERS_CPUS-2}
WORKERS_MEMORY=${WORKERS_MEMORY-4}
CLUSTER_ID=${CLUSTER_ID-2}
POD_CIDR=${POD_CIDR-10.3.0.0/16}
SVC_CIDR=${SVC_CIDR-10.4.0.0/16}

# Empty /var/db/dhcpd_leases if you ran out of IP addresses on your Mac
echo "Deploying Kubernetes"
. deploy-k3s.sh

echo "Deploying Prometheus CRDs"
helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds

echo "Deploying Linkerd"
. deploy-linkerd.sh

echo "Creating link from the remote cluster into the central cluster"
if [[ -e lgtm-central-kubeconfig.yaml && -e lgtm-remote-kubeconfig.yaml ]]; then
  export KUBECONFIG="lgtm-central-kubeconfig.yaml:lgtm-remote-kubeconfig.yaml"
  kubectl config use-context $CONTEXT
fi
linkerd mc link --context lgtm-central --cluster-name lgtm-central \
  | kubectl apply --context lgtm-remote -f -

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
