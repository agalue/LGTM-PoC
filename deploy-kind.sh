#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "docker" "kind" "cilium" "jq"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CONTEXT=${CONTEXT-kind} # Kubeconfig Profile and cluster sub-domain
WORKERS=${WORKERS-2} # Number of worker nodes in the clusters
SUBNET=${SUBNET-248} # Last octet from the /29 CIDR subnet to use for Cilium L2/LB
HOST_IP=${HOST_IP-$(ifconfig en0 inet | grep inet | awk '{print $2}')} # The IP address of your machine

MASTER=${CONTEXT}-control-plane

# Abort if the cluster exists; if so, ensure the kubeconfig is exported
if [[ $(kind get clusters | tr '\n' ' ') = *${CONTEXT}* ]]; then
  echo "Cluster ${CONTEXT} already started"
  kubectl config use-context kind-${CONTEXT}
  return
fi

# Deploy Kind Cluster
cat <<EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CONTEXT}
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    ---
    apiVersion: kubeadm.k8s.io/v1beta3
    kind: ClusterConfiguration
    networking:
      dnsDomain: "${CONTEXT}.cluster.local"
- role: worker
- role: worker
- role: worker
networking:
  ipFamily: ipv4
  apiServerAddress: ${HOST_IP}
  disableDefaultCNI: true
  kubeProxyMode: none
EOF

cilium install --version 1.15.1 --wait \
  --set cluster.name=${CONTEXT} \
  --set ipam.mode=kubernetes \
  --set devices=eth+ \
  --set l2announcements.enabled=true \
  --set externalIPs.enabled=true \
  --set socketLB.enabled=true \
  --set socketLB.hostNamespaceOnly=true

cilium status --wait

NETWORK=$(docker network inspect kind \
  | jq -r '.[0].IPAM.Config[] | select(.Gateway != null) | .Subnet')

cat <<EOF | kubectl apply -f -
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: ${CONTEXT}-pool
spec:
  cidrs:
  - cidr: "${NETWORK%.*}.${SUBNET}/29"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: ${CONTEXT}-policy
spec:
  interfaces:
  - eth0
  externalIPs: true
  loadBalancerIPs: true
EOF

# Create a patched Kubeconfig compatible with other solutions
CONFIG=${CONTEXT}-kubeconfig.yaml
kubectl config view --minify --flatten | sed 's/kind-//' > $CONFIG
