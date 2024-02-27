# LGTM PoC

In the world of Kubernetes, Prometheus is considered the best tool to monitor the cluster and all its running components. Microservices, specifically those written in Go, can expose their metrics in Prometheus format. Additionally, there are numerous exporters available for applications that cannot natively do so. Therefore, Mimir is the ideal way to consolidate metrics from multiple Kubernetes clusters along with the applications running on each of them.

When it comes to log aggregation solutions, Loki is a much simpler and easier-to-manage option compared to the traditional ELK stack. Similarly, Tempo is the best choice for traces due to similar reasons.

## Architecture

![Architecture](architecture-0.png)

We will use Grafana Agent to send traces to Tempo on all environments to have multi-tenancy on traces, deployed as a `Deployment`.

We will use Promtail to send logs to Loki on all environments deployed as a `DaemonSet`.

We will use Prometheus to send metrics to Mimir on all environments.

We will have *two* Kubernetes clusters, one with the LGTM Stack exposing Grafana via Ingress (`lgtm-central`), and another with a sample application, generating metrics, logs, and traces (`lgtm-remote`).

As Zero Trust is becoming more important nowadays, we'll use [Linkerd](https://linkerd.io/) to secure the communication within each cluster and the communication between the clusters, which gives us the ability to have a secure channel without implementing authentication, authorization, and encryption on our own.

![Architecture](architecture-1.png)

We will use [Kind](https://kind.sigs.k8s.io/) via [Docker](https://www.docker.com/) for the clusters. Each cluster would have [Cilium](https://cilium.io/) deployed as CNI and as an L2/LB, mainly because the Linkerd Gateway for Multi-Cluster requires a Load Balancer service (that way we wouldn't need MetalLB). For each cluster, we'll have a different Cluster Domain.

For the LB, the Central cluster will use segment `x.x.x.248/29`, and the Remote cluster will employ `x.x.x.240/29` from the Docker network created by `kind`.

The Multi-Cluster Link is originated on the Remote Cluster, targeting the Central Cluster, meaning the Service Mirror Controller lives on the Remote Cluster.

Each remote cluster would be a Tenant in terms of Mimir, Tempo and Loki. For demo purposes, Grafana has Data Sources to get data from the Local components and Remote components.

Mimir supports Tenant Federation if you need to look at metrics from different tenants simultaneously.

> **WARNING:** There will be several worker nodes between both clusters, so we recommend having a machine with 8 Cores and 32GB of RAM to deploy the lab, or you would have to make manual adjustments. I choose `kind` instead of `minikube` as I feel the performance is better; having multiple nodes is more manageable and works better on ARM-based Macs. All the work done here was tested on an Intel-based Mac running [OrbStack](https://orbstack.dev/) instead of Docker Desktop and on a Linux Server running Rocky Linux 9. It is worth noticing that OrbStack outperforms Docker Desktop and allows you to access all containers and IPs (which also applies to Kubernetes services) as if you were running on Linux.

### Data Sources

The following is the list of Data Sources on the Central Grafana:

* `Mimir Local` to get metrics from the local Mimir (long term). The default DS for Prometheus, can also be used, for short periods.
* `Tempo Local` to get traces from the local cluster.
* `Loki Local` to get logs from the local cluster.

* `Mimir Remote` to get metrics from the remote cluster.
* `Tempo Remote` to get traces from the remote cluster.
* `Loki Remote` to get logs from the remote cluster.

## Requirements

* [Docker](https://www.docker.com/) ([OrbStack](https://orbstack.dev/) recommend if you're on macOS)
* [Kubectl](https://kubernetes.io/docs/tasks/tools/)
* [Kind](https://kind.sigs.k8s.io/)
* [Helm](https://helm.sh/)
* [Step CLI](https://smallstep.com/docs/step-cli)
* [Linkerd CLI](https://linkerd.io/2.14/getting-started/#step-1-install-the-cli)
* [Cilium CLI](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli)
* [Jq](https://jqlang.github.io/jq/)

The solution has been designed and tested only on an Intel-based Mac and a Linux Server. You might need to change the scripts to run them on a different operating system.

## Start

* Create anchor and issuer certificates for Linkerd:

```bash
./deploy-certs.sh
```

* Deploy Central Cluster with LGTM stack (K8s context: `lgtm-central`):

```bash
./deploy-central.sh
```

* Deploy Remote Cluster with sample application linked to the Central Cluster (K8s context: `lgtm-remote`):

```bash
./deploy-remote.sh
```

## Validation

### Linkerd Multi-Cluster

The `linkerd` CLI can help to verify if the inter-cluster communication is working. From the `lgtm-remote` cluster, you can do the following:

```bash
➜  linkerd mc check --context kind-lgtm-remote
linkerd-multicluster
--------------------
√ Link CRD exists
√ Link resources are valid
	* lgtm-central
√ remote cluster access credentials are valid
	* lgtm-central
√ clusters share trust anchors
	* lgtm-central
√ service mirror controller has required permissions
	* lgtm-central
√ service mirror controllers are running
	* lgtm-central
√ all gateway mirrors are healthy
	* lgtm-central
√ all mirror services have endpoints
√ all mirror services are part of a Link
√ multicluster extension proxies are healthy
√ multicluster extension proxies are up-to-date
√ multicluster extension proxies and cli versions match

Status check results are √
```

```bash
➜  linkerd mc gateways --context kind-lgtm-remote
CLUSTER       ALIVE    NUM_SVC      LATENCY
lgtm-central  True           3          2ms
```

When linking `lgtm-remote` to `lgtm-central` via Linkerd Multi-Cluster, the CLI will use the Kubeconfig from the `lgtm-central` to configure the service mirror controller on the `lgtm-remote` cluster.

You can inspect the runtime kubeconfig as follows:

```bash
kubectl get secret --context kind-lgtm-remote \
  -n linkerd-multicluster cluster-credentials-lgtm-central \
  -o jsonpath='{.data.kubeconfig}' | base64 -d; echo
```

To see the permissions associated with the `ServiceAccount` on the central cluster:

```bash
➜  kubectl describe clusterrole linkerd-service-mirror-remote-access-default --context kind-lgtm-central
Name:         linkerd-service-mirror-remote-access-default
Labels:       app.kubernetes.io/managed-by=Helm
              linkerd.io/extension=multicluster
Annotations:  linkerd.io/created-by: linkerd/helm stable-2.14.10
              meta.helm.sh/release-name: linkerd-multicluster
              meta.helm.sh/release-namespace: linkerd-multicluster
PolicyRule:
  Resources                        Non-Resource URLs  Resource Names    Verbs
  ---------                        -----------------  --------------    -----
  events                           []                 []                [create patch]
  configmaps                       []                 [linkerd-config]  [get]
  endpoints                        []                 []                [list get watch]
  pods                             []                 []                [list get watch]
  services                         []                 []                [list get watch]
  replicasets.apps                 []                 []                [list get watch]
  jobs.batch                       []                 []                [list get watch]
  endpointslices.discovery.k8s.io  []                 []                [list get watch]
  servers.policy.linkerd.io        []                 []                [list get watch]
  ```

> Note that the `ServiceAccount` exists on both cluster.

In other words, to create a link from `lgtm-remote` to `lgtm-central`, we run the following assuming the current context is assigned to `lgtm-remote`:
```bash
linkerd mc link --context kind-lgtm-central --cluster-name lgtm-central | kubectl apply --context kind-lgtm-remote -f -
```

With the `--context` parameter, we specify the "target" cluster and assign a name to it (which will be part of the exposed service names in the remote cluster). If we inspect the YAML file generated by the above command, we can see a secret that contains `kubeconfig`; that's how to reach the `lgtm-central` cluster, and that will be taken from your local kubeconfig, but using a user called `linkerd-service-mirror-remote-access-default` (a service account in the `linkerd-multicluster` namespace that exists in both clusters).

Another service account called `linkerd-service-mirror-lgtm-central` for the mirror service will be created.

So, the Linkerd Gateway runs in both clusters, but the Mirror Service runs in the remote cluster (where you created the link from).

### LGTM Stack

If you're running on Linux or macOS with OrbStack, you should add an entry to `/etc/hosts` for `grafana.example.com` pointing to the IP that the Ingress will get on the Central cluster (the script will tell you that IP), or:

```bash
kubectl get svc --context kind-lgtm-central -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

If you're using Docker for Desktop on macOS, I created a script to deploy HAProxy which allows you to access the Ingress Service via localhost:

```bash
./deploy-proxy
```

In that case, use `127.0.0.1` when modifying `/etc/hosts` instead of the LB IP.

Then, access the Grafana WebUI available at `https://grafana.example.com` and accept the warning as the site uses a certificate signed by a self-signed CA.

The password for the `admin` account is defined in [values-prometheus-central.yaml](./values-prometheus-central.yaml) (i.e., `Adm1nAdm1n`). From the Explore tab, you should be able to access the data collected locally and received from the remote location using the data sources described initially.

Within the [dashboards](./dashboards/) subdirectory, you should find some sample Mimir dashboards (the README under this folder explains how to generate them). More importantly, there is a dashboard for the TNS App that you can use to visualize metrics from more locations based on the metrics stored in the central location. If you check the logs for that application (`tns` namespace), you can visualize the remote logs stored on the central Loki and the traces.

## Shutdown

```bash
kind delete cluster --name lgtm-central
kind delete cluster --name lgtm-remote
```

If you started the HAProxy:

```bash
docker stop haproxy
docker rm haproxy
```