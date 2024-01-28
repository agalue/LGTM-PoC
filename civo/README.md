# Deploy LGTM Lab in CIVO

The following assumes you have an account on [CIVO](https://www.civo.com/) and the [CLI](https://www.civo.com/docs/overview/civo-cli) is already installed and ready on your computer.

> If you're new to CIVO, you might need to request a Quota increase to ensure you can deploy both clusters as described here. There are going to be 2 K8s clusters with 5 worker nodes (instances) across both of them with a total of 16 CPUs, 32 GB of Memory, 484 GB of Disk, and 21 Volumes.

* Create anchor and issuer certificates for Linkerd:

```bash
./deploy-certs.sh
```

* Create the Central cluster in CIVO and Update Cilium (see [here](https://linkerd.io/2.14/reference/cluster-configuration/#cilium)):

```bash
civo k3s create lgtm-central \
  --region NYC1 \
  --version 1.28.2-k3s1 \
  --cni-plugin cilium \
  --nodes 3 \
  --size g4s.kube.large \
  --remove-applications traefik2-nodeport \
  --save --merge --switch --wait --yes

if [ $? -eq 0 ]; then
  cilium config set -r=false cluster-id 1 && \
  cilium config set -r=false cluster-name lgtm-central && \
  cilium config set bpf-lb-sock-hostns-only true
  cilium status --wait
fi
```

* Deploy Central Cluster with LGTM stack (K8s context: `lgtm-central`):

```bash
DOMAIN=cluster.local ./deploy-central.sh
```

* Create the Remote cluster in CIVO and Update Cilium:

```bash
civo k3s create lgtm-remote \
  --region NYC1 \
  --version 1.28.2-k3s1 \
  --cni-plugin cilium \
  --nodes 2 \
  --size g4s.kube.medium \
  --remove-applications traefik2-nodeport \
  --save --merge --switch --wait --yes

if [ $? -eq 0 ]; then
  cilium config set -r=false cluster-id 2 && \
  cilium config set -r=false cluster-name lgtm-remote && \
  cilium config set bpf-lb-sock-hostns-only true
  cilium status --wait
fi
```

* Deploy Remote Cluster with sample application linked to the Central Cluster (K8s context: `lgtm-remote`):

```bash
DOMAIN=cluster.local ./deploy-remote.sh
```

## Validation

Follow all the directions from the main README file.

## Shutdown

```bash
civo k3s delete lgtm-remote
civo k3s delete lgtm-central
for name in $(civo volume ls -o json | jq -r '.[] | .name'); do civo volume delete $name -y; done
```
