#!/bin/bash

# The script will create one dedicated master node and a set of worker nodes.
# If the number of workers is zero, there is going to be a single-node cluster.
# In this case the single-node will use the provided CPU, Memory, and Disk settings from the workers nodes.

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "multipass"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CONTEXT=${CONTEXT-k3s} # Kubeconfig Profile and cluster sub-domain
MASTER_CPUS=${MASTER_CPUS-1} # Number of CPUS for the master node
MASTER_MEMORY=${MASTER_MEMORY-3} # Memory size in GB for the master node
WORKERS=${WORKERS-2} # Number of worker nodes in the clusters
WORKERS_CPUS=${WORKERS_CPUS-2} # Number of CPUS per worker node
WORKERS_MEMORY=${WORKERS_MEMORY-4} # Memory size in GB per worker node
WORKERS_DISK=${WORKERS_DISK-40} # Disk size in GB per worker node
SUBNET=${SUBNET-248} # Last octet from the /29 CIDR subnet to use for Cilium L2/LB

CONFIG=${CONTEXT}-kubeconfig.yaml
MASTER=${CONTEXT}-master

# Abort if the master node exists; if so, ensure the kubeconfig is exported
if [ "$(multipass info ${MASTER} 2>/dev/null | grep IPv4 | awk '{print $2}')" != "" ]; then
  echo "Cluster ${CONTEXT} already started"
  export KUBECONFIG=${CONFIG}
  kubectl config use-context ${CONTEXT}
  return
fi

# Deploy master node
multipass launch -c ${MASTER_CPUS} -m ${MASTER_MEMORY}g -n ${MASTER}
MASTER_IP=$(multipass info ${MASTER} | grep IPv4 | awk '{print $2}')
cat <<EOF | multipass exec ${MASTER} -- sudo bash
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/01-cilium.conf
systemctl restart systemd-sysctl
echo "xt_socket" > /etc/modules-load.d/cilium.conf
modprobe xt_socket

mkdir -p /etc/rancher/k3s

cat <<CFG | tee /etc/rancher/k3s/config.yaml
node-ip: ${MASTER_IP}
tls-san: ${MASTER_IP}
bind-address: ${MASTER_IP}
write-kubeconfig-mode: '644'
cluster-domain: ${CONTEXT}.cluster.local
flannel-backend: none
disable-kube-proxy: true
disable-network-policy: true
disable-cloud-controller: true
disable:
- traefik
- servicelb
CFG

curl -sfL https://get.k3s.io | sh -
curl -sfL --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

cilium install --version 1.15.1 --wait \
--set cluster.name=${CONTEXT} \
--set ipam.mode=kubernetes \
--set devices=ens+ \
--set l2announcements.enabled=true \
--set externalIPs.enabled=true \
--set socketLB.enabled=true \
--set socketLB.hostNamespaceOnly=true

cilium status --wait

cat <<CFG | kubectl apply -f -
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: ${CONTEXT}-pool
spec:
  cidrs:
  - cidr: "${MASTER_IP%.*}.${SUBNET}/29"
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
  - ens3
  externalIPs: true
  loadBalancerIPs: true
CFG

if (( ${WORKERS} > 0 )); then
  kubectl taint node ${MASTER} node-role.kubernetes.io/master:NoSchedule --overwrite
fi
EOF

# Extract kubeconfig
multipass exec ${MASTER} -- cat /etc/rancher/k3s/k3s.yaml | sed "s/default/${CONTEXT}/" > ${CONFIG}
chmod 600 ${CONFIG}
export KUBECONFIG=${CONFIG}
kubectl config use-context ${CONTEXT}

# Deploy the worker nodes
if (( ${WORKERS} > 0 )); then
  TOKEN=$(multipass exec ${MASTER} sudo cat /var/lib/rancher/k3s/server/node-token)
  for i in $(seq 1 ${WORKERS}); do
    WORKER=${CONTEXT}-worker${i}
    multipass launch -c ${WORKERS_CPUS} -m ${WORKERS_MEMORY}g -d ${WORKERS_DISK}g -n ${WORKER}
    cat <<EOF | multipass exec ${WORKER} -- sudo bash
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/01-cilium.conf
systemctl restart systemd-sysctl
echo "xt_socket" > /etc/modules-load.d/cilium.conf
modprobe xt_socket
curl -sfL https://get.k3s.io | K3S_URL='https://$MASTER_IP:6443' K3S_TOKEN='$TOKEN' sh -
EOF
    multipass exec ${MASTER} -- kubectl label nodes ${WORKER} kubernetes.io/role=worker
  done
fi
