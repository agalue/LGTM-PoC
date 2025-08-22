#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "docker" "kind" "cilium" "kubectl" "jq" "helm"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CONTEXT=${CONTEXT-kind} # Kubeconfig profile
WORKERS=${WORKERS-2} # Number of worker nodes in the clusters
SUBNET=${SUBNET-248} # Last octet from the /29 CIDR subnet to use for LoadBalancer IPs
CLUSTER_ID=${CLUSTER_ID-1}
POD_CIDR=${POD_CIDR-10.244.0.0/16} # Pod subnet for the cluster (when using Cilium, it must be under 10.0.0.0/8 for ipv4NativeRoutingCIDR)
SVC_CIDR=${SVC_CIDR-10.96.0.0/16} # Must differ from Kind's Docker Network
HOST_IP=${HOST_IP-127.0.0.1} # The IP address of your machine to expose API Server (don't change when using Docker-based solutions)
CILIUM_ENABLED=${CILIUM_ENABLED-yes} # Set to 'yes' to use Cilium as CNI or 'no' to use default CNI plus MetalLB
CILIUM_CLUSTER_MESH_ENABLED=${CILIUM_CLUSTER_MESH_ENABLED-no}

HUBBLE_ENABLED="false"
ENCRYPTION_ENABLED="false"
if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" == "yes" ]]; then
  ENCRYPTION_ENABLED="true" # Assumes Linkerd is not present.
  HUBBLE_ENABLED="true" # Assumes Linkerd-Viz unavailable.
  if [ ! -f "cilium-ca.crt" ]; then
    echo "cilium-ca.crt not found; please run deploy-certs.sh"
    exit 1
  fi
fi

# Abort if the cluster exists; if so, ensure the kubeconfig is exported
CLUSTERS=($(kind get clusters | tr '\n' ' '))
if [[ ${#CLUSTERS[@]} > 0 ]] && [[ " ${CLUSTERS[@]} " =~ " ${CONTEXT} " ]]; then
  echo "Cluster ${CONTEXT} already started"
  kubectl config use-context kind-${CONTEXT}
  return
fi

WORKER_YAML=""
for ((i = 1; i <= WORKERS; i++)); do
  WORKER_YAML+=$(cat <<EOF
- role: worker
  labels:
    topology.kubernetes.io/region: ${CONTEXT}
    topology.kubernetes.io/zone: zone${i}
EOF
)$'\n'
done

NETWORKING_CONFIG="ipFamily: ipv4"
if [[ "${CILIUM_ENABLED}" == "yes" ]]; then
  # Cilium configuration: disable default CNI and kube-proxy
  NETWORKING_CONFIG+=$'\n  disableDefaultCNI: true\n  kubeProxyMode: none'
fi

# Deploy Kind Cluster
cat <<EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CONTEXT}
nodes:
- role: control-plane
${WORKER_YAML}
networking:
  ${NETWORKING_CONFIG}
  apiServerAddress: ${HOST_IP}
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SVC_CIDR}
EOF

NETWORK=$(docker network inspect kind \
  | jq -r '.[0].IPAM.Config[] | select(.Gateway != null) | .Subnet' | grep -v ':')
CIDR=""
if [[ "$NETWORK" == *"/16" ]]; then
  CIDR="${NETWORK%.*.*}.255.${SUBNET}/29"
fi
if [[ "$NETWORK" == *"/24" ]]; then
  CIDR="${NETWORK%.*}.${SUBNET}/29"
fi
if [[ "$CIDR" == "" ]]; then
  echo "cannot extract LB CIDR from network $NETWORK"
  exit 1
fi

if [[ "${CILIUM_ENABLED}" == "yes" ]]; then
  echo "Installing Cilium CNI..."

  if [ -e cilium-ca.crt ] && [ -e cilium-ca.key ]; then
    kubectl create secret generic cilium-ca -n kube-system --from-file=ca.crt=cilium-ca.crt --from-file=ca.key=cilium-ca.key
    kubectl label secret -n kube-system cilium-ca app.kubernetes.io/managed-by=Helm
    kubectl annotate secret -n kube-system cilium-ca meta.helm.sh/release-name=cilium
    kubectl annotate secret -n kube-system cilium-ca meta.helm.sh/release-namespace=kube-system
  fi

  cilium install --wait \
    --set ipv4NativeRoutingCIDR=10.0.0.0/8 \
    --set routingMode=native \
    --set autoDirectNodeRoutes=true \
    --set bpf.masquerade=false \
    --set cluster.id=${CLUSTER_ID} \
    --set cluster.name=${CONTEXT} \
    --set ipam.mode=kubernetes \
    --set cni.exclusive=false \
    --set envoy.enabled=false \
    --set devices=eth+ \
    --set l2announcements.enabled=true \
    --set externalIPs.enabled=true \
    --set socketLB.enabled=true \
    --set socketLB.hostNamespaceOnly=true \
    --set k8sClientRateLimit.qps=50 \
    --set k8sClientRateLimit.burst=100 \
    --set encryption.enabled=${ENCRYPTION_ENABLED} \
    --set encryption.type=wireguard \
    --set hubble.relay.enabled=${HUBBLE_ENABLED} \
    --set hubble.ui.enabled=${HUBBLE_ENABLED}

  cilium status --wait --ignore-warnings

  cat <<EOF | kubectl apply -f -
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: ${CONTEXT}-pool
spec:
  blocks:
  - cidr: "${CIDR}"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: ${CONTEXT}-policy
spec:
  nodeSelector:
    matchExpressions:
    - key: node-role.kubernetes.io/control-plane
      operator: DoesNotExist
  interfaces:
  - ^eth[0-9].*
  externalIPs: true
  loadBalancerIPs: true
EOF

  if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" == "yes" ]]; then
    cilium clustermesh enable --service-type LoadBalancer --enable-kvstoremesh=false
    cilium clustermesh status --wait
  fi
else
  echo "Installing MetalLB LoadBalancer..."

  helm upgrade --install metallb metallb/metallb \
    --namespace metallb-system \
    --create-namespace \
    --wait

  cat <<EOF | kubectl apply -f -
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${CONTEXT}-pool
  namespace: metallb-system
spec:
  addresses:
  - ${CIDR}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${CONTEXT}-l2advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - ${CONTEXT}-pool
EOF
fi

helm upgrade --install metrics-server metrics-server/metrics-server \
 -n kube-system --set args={--kubelet-insecure-tls}
