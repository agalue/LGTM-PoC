#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "multipass" "helm"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CONTEXT=${CONTEXT-k3s} # Kubeconfig Profile and cluster sub-domain
NODES=${NODES-3} # Number of NODES in the clusters
CPUS=${CPUS-2} # Number of CPUS per node
MEMORY=${MEMORY-4} # MEMORY size in GB
DISK=${DISK-40} # DISK size in GB
SUBNET=${SUBNET-248} # Last octet from the /29 CIDR SUBNET to use for MetalLB

CONFIG=${CONTEXT}-kubeconfig.yaml
MASTER=${CONTEXT}-node1

if [ "$(multipass info ${MASTER} 2>/dev/null | grep IPv4 | awk '{print $2}')" != "" ]; then
  echo "Cluster ${CONTEXT} already started"
  export KUBECONFIG=${CONFIG}
  kubectl config use-context ${CONTEXT}
  return
fi

multipass launch -c ${CPUS} -m ${MEMORY}g -d ${DISK}g -n ${MASTER}
cat <<EOF | multipass exec ${MASTER} -- sudo bash
mkdir -p /etc/rancher/k3s
cat <<CFG >/etc/rancher/k3s/config.yaml
write-kubeconfig-mode: '644'
cluster-domain: ${CONTEXT}.cluster.local
disable:
- traefik
- servicelb
CFG
curl -sfL https://get.k3s.io | sh -
EOF

TOKEN=$(multipass exec ${MASTER} sudo cat /var/lib/rancher/k3s/server/node-token)
MASTER_IP=$(multipass info ${MASTER} | grep IPv4 | awk '{print $2}')
for i in $(seq 2 ${NODES}); do
  worker=${CONTEXT}-node${i}
  multipass launch -c ${CPUS} -m ${MEMORY}g -d ${DISK}g -n ${worker}
  multipass exec ${worker} -- bash -c "curl -sfL https://get.k3s.io | K3S_URL=\"https://$MASTER_IP:6443\" K3S_TOKEN=\"$TOKEN\" sh -"
done

multipass transfer ${MASTER}:/etc/rancher/k3s/k3s.yaml ${CONFIG}
sed -i .tmp "s/default/${CONTEXT}/" ${CONFIG}
sed -i .tmp "s/127.0.0.1/${MASTER_IP}/" ${CONFIG}
rm *.tmp
chmod 600 ${CONFIG}

export KUBECONFIG=${CONFIG}
kubectl config use-context ${CONTEXT}

helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace --wait
cat <<EOF | kubectl apply -f -
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${CONTEXT}-pool
  namespace: metallb-system
spec:
  addresses:
  - ${MASTER_IP%.*}.${SUBNET}/29
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${CONTEXT}-l2adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - ${CONTEXT}-pool
  interfaces:
  - ens3
EOF
