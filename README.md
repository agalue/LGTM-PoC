# LGTM PoC

In the world of Kubernetes, Prometheus is considered the best tool to monitor the cluster and all its running components. Microservices, specifically those written in Go, can expose their metrics in Prometheus format. Additionally, there are numerous exporters available for applications that cannot natively do so. Therefore, [Mimir](https://grafana.com/docs/mimir/latest/) is the ideal way to consolidate metrics from multiple Kubernetes clusters along with the applications running on each of them.

When it comes to log aggregation solutions, [Loki](https://grafana.com/docs/loki/latest/) is a much simpler and easier-to-manage option compared to the traditional ELK stack. Similarly, [Tempo](https://grafana.com/docs/tempo/latest/) is the best choice for traces due to similar reasons.

## Architecture

![Architecture](architecture-0.png)

We have a central cluster running Grafana's LGTM stack on Kubernetes. Then, several client or remote clusters connected via "Cluster Mesh" to the central cluster to send metrics, logs, and traces to the LGTM stack.

The remote clusters show different possibilities for deploying the solution.

In the first scenario, we have Prometheus collecting data from the Kubernetes clusters and the applications, and it uses the Remote Write API to forward data to Mimir in the central cluster. Similarly, we have [Vector](https://vector.dev/) for logs (forwarding data to central Loki) and [Grafana Alloy](https://grafana.com/docs/alloy/latest/) for traces (forwarding data to central Tempo).

In the second scenario, Grafana Alloy handles all the observability data (metrics, logs, and traces) and forwards them to the central LGTM stack. In this case, Alloy does the work of Vector and Prometheus (including collecting metrics from the Kubernetes cluster and managing Prometheus CRDs).

In the third scenario, we have Prometheus handling the cluster metrics and the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) handling metrics, logs, and traces received via OTLP from the applications running in the cluster and forwarding the data to the central LGTM stack.

Each cluster (including the central one) will be a tenant on Mimir, Loki, and Tempo to separate the data from each other.

Finally, on the central cluster, we have Prometheus collecting metrics and sending them to the local Mimir via Remote Write API, Vector doing the same for logs to Loki, and Grafana Alloy for traces to Tempo. Technically speaking, we don't need Grafana Alloy on the central cluster as Tempo is running there, but it is deployed for consistency, or if you eventually need to perform advanced tasks like [Tail-based sampling](https://grafana.com/docs/tempo/latest/configuration/grafana-agent/tail-based-sampling/).

Vector is deployed as a `DaemonSet` (Agent mode) to forward logs to Loki.

When using Prometheus to send metrics to Mimir, the idea is to utilize the CRDs (`ServiceMonitor` and `PodMonitor` resources) to monitor local applications (when deployed with the operator or through the Kube Stack).

For this PoC, we will have *two* Kubernetes clusters, one with the LGTM Stack exposing Grafana via Ingress (`lgtm-central`) and another with a sample application, generating metrics, logs, and traces using the [TNS](https://github.com/grafana/tns) Observability Demo App from Grafana (`lgtm-remote`, based on the first scenario).

Optionally, there is a third cluster running the [OpenTelemetry Demo App](https://opentelemetry.io/docs/demo/), which is configured via Helm to send metrics to the LGTM stack using the OTEL Collector (`lgtm-remote-otel`, based on the third scenario).

As Zero Trust is becoming more important nowadays, we'll use either [Linkerd](https://linkerd.io/), [Istio](https://istio.io/), or [Cilium Cluster Mesh](https://cilium.io/use-cases/cluster-mesh/) to secure the communication within each cluster and the communication between the clusters, which gives us the ability to have a secure channel without implementing authentication, authorization, and encryption ourselves.

We will use [Kind](https://kind.sigs.k8s.io/) via [Docker](https://www.docker.com/) for the clusters. Each cluster would have [Cilium](https://cilium.io/) deployed as CNI and as an L2/LB, mainly because the Service Mesh Gateway for Multi-Cluster requires a Load Balancer service (that way we wouldn't need MetalLB).

For the LB, the Central cluster will use segment `x.x.x.248/29`, and the Remote cluster will employ `x.x.x.240/29` (and the OTEL remote would use `x.x.x.232/29`) from the Docker network created by `kind`.

Each remote cluster would be a Tenant in terms of Mimir, Tempo and Loki. For demo purposes, Grafana has Data Sources to get data from the Local components and Remote components.

Mimir supports Tenant Federation if you need to look at metrics from different tenants simultaneously.

As Cilium is available on each cluster, and the scripts are arranged in a way that there won't be IP Address collisions between all the clusters (for Pod and Services), it is possible to replace Linkerd or Istio with Cilium [ClusterMesh](https://cilium.io/use-cases/cluster-mesh/) with Encryption enabled. We will be using [Wireguard](https://www.wireguard.com/) as it is easier to deploy than IPSec and will encrypt the communication between worker nodes and clusters. The difference between Cilium and a Service Mesh like Istio or Linkerd is that Pod-to-Pod communication won't be encrypted when the instances run in the same worker node, and mTLS won't be involved.

If you want to use Cilium ClusterMesh instead of Linkerd, run the following before deploying the clusters:

```bash
export CILIUM_CLUSTER_MESH_ENABLED=yes
```

> The above will disable Linkerd and Istio.

To enable Istio in proxy-mode:

```bash
export CILIUM_CLUSTER_MESH_ENABLED=no
export ISTIO_ENABLED=yes
```

To enable Istio in ambient-mode:

```bash
export CILIUM_ENABLED=no
export CILIUM_CLUSTER_MESH_ENABLED=no
export ISTIO_ENABLED=yes
export ISTIO_PROFILE=ambient
```

> **WARNING**: With Istio version 1.27.0, there are DNS issues for cross-cluster resolution when Cilium is enabled. That's why I suggest disabling Cilium and relying on MetalLB for LoadBalancers.

All the scripts are smart enough to deal with all situations properly.

> **WARNING:** There will be several worker nodes between both clusters, so we recommend having a machine with 8 Cores and 32GB of RAM to deploy the lab, or you would have to make manual adjustments. I choose `kind` instead of `minikube` as I feel the performance is better; having multiple nodes is more manageable and works better on ARM-based Macs. All the work done here was tested on an Intel-based Mac running [OrbStack](https://orbstack.dev/) instead of Docker Desktop and on a Linux Server running Rocky Linux 9. It is worth noticing that OrbStack outperforms Docker Desktop and allows you to access all containers and IPs (which also applies to Kubernetes services) as if you were running on Linux.

### Linkerd Multi Cluster

![Linkerd MC Architecture](architecture-1.png)

Linkerd creates a mirrored service automatically when linking clusters, appending the name of the target service to it. For instance, in `lgtm-central`, accessing Mimir locally would be `mimir-distributor.mimir.svc`, whereas accessing it from the `lgtm-remote` cluster would be `mimir-distributor-lgtm-central.mimir.svc`.

Due to a [change](https://buoyant.io/blog/clarifications-on-linkerd-2-15-stable-announcement) introduced by Buoyant about the Linkerd artifacts, the latest `stable` version available via Helm charts is 2.14 (even if the actual latest version is newer). Because of that, we'll be using the `edge` release by default.

### Istio Multi Cluster

> **WARNING:** Istio support is a work in progress.

Setting `appProtocol: tcp` for all GRPC services (especially `memberlist`) helps with [protocol selection](https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/) and ensuring the presence of [headless services](https://istio.io/latest/docs/ops/configuration/traffic-management/traffic-routing/#headless-services) (i.e., `clusterIP: None`) improves traffic routing guaranteeing that the proxy will have endpoints per Pod IP address, allowing all Grafana applications to work correctly (as some microservices require direct pod-to-pod communication by Pod IP). Modern Helm charts for Loki, Tempo, and Mimir allow configuration `appProtocol`; there are already headless services for all the microservices. The configuration flexibility varies, but everything seems to be working.

The PoC assumes Istio [multi-cluster](https://istio.io/latest/docs/setup/install/multicluster/primary-remote_multi-network/) using multi-network, which requires an Istio Gateway. In other words, the environment assumes we're interconnecting two clusters from different networks using Istio.

Unlike Linkerd, the services declared on the central cluster are reachable using the same FQDN as in the local cluster. The Istio Proxies are configured so that the DNS resolution and routing works as intended.

### Cilium Cluster

When using Cilium ClusterMesh, the user is responsible for creating the service with the same configuration on each cluster (although annotated with `service.cilium.io/shared=false`). That means reaching Mimir from `lgtm-remote` would be exactly like accessing it from `lgtm-central` (similar to Istio).

### Data Sources

The following is the list of Data Sources on the Central Grafana:

* `Mimir Local` to get metrics from the local Mimir (long term). The default DS for Prometheus, can also be used, for short periods.
* `Tempo Local` to get traces from the local cluster.
* `Loki Local` to get logs from the local cluster.

If you're running the remote cluster with the TNS Demo Application:

* `Mimir Remote TNS` to get metrics from the remote cluster.
* `Tempo Remote TNS` to get traces from the remote cluster.
* `Loki Remote TNS` to get logs from the remote cluster.

If you're running the remote cluster with the OTEL Demo Application:

* `Mimir Remote OTEL` to get metrics from the second remote cluster running the OTEL Demo.
* `Tempo Remote OTEL` to get traces from the second remote cluster running the OTEL Demo.
* `Loki Remote OTEL` to get logs from the second remote cluster running the OTEL Demo.

## Requirements

* [Docker](https://www.docker.com/) ([OrbStack](https://orbstack.dev/) recommended when running on macOS)
* [Kubectl](https://kubernetes.io/docs/tasks/tools/)
* [Kind](https://kind.sigs.k8s.io/)
* [Helm](https://helm.sh/)
* [Step CLI](https://smallstep.com/docs/step-cli)
* [Linkerd CLI](https://linkerd.io/2.16/getting-started/#step-1-install-the-cli), if you're going to use Linkerd
* [Istio CLI](https://istio.io/latest/docs/setup/install/istioctl/), if you're going to use Istio
* [Cilium CLI](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli)
* [Jq](https://jqlang.github.io/jq/)

The solution has been designed and tested only on an Intel-based Mac and a Linux Server. You might need to change the scripts to run them on a different operating system.

## Start

> Remember that the scripts use Linkerd by default. Check the notes above to use Istio or Cilium ClusterMesh.

* Create anchor and issuer certificates for Cilium, Linkerd and Istio:

```bash
./deploy-certs.sh
```

* To deploy Central Cluster with LGTM stack (K8s context: `lgtm-central`), run the following:

```bash
./deploy-central.sh
```

* To deploy Remote Cluster with sample application linked to the Central Cluster (K8s context: `lgtm-remote`), run the following:

```bash
./deploy-remote.sh
```

If you encounter issues on Linux, Kind recommends running the following:
```bash
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
```

* To deploy Remote Cluster with sample application linked to the Central Cluster (K8s context: `lgtm-remote-otel`), run the following:

```bash
./deploy-remote-otel.sh
```
> Note that running both remote clusters simultaneously would require having enough resources on your machine.

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
lgtm-central  True           4          2ms
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

> If you're using the OpenTelemetry Demo cluster, replace `lgtm-remote` with `lgtm-remote-otel`.

### Istio Multi-Cluster

Here is a sequence of commands that demonstrate that multi-cluster works, assuming you deployed the TLS remote cluster:

```bash
❯ istioctl remote-clusters --context kind-lgtm-remote
NAME             SECRET                                            STATUS     ISTIOD
lgtm-remote                                                        synced     istiod-64f7d85469-ljhhm
lgtm-central     istio-system/istio-remote-secret-lgtm-central     synced     istiod-64f7d85469-ljhhm
```

If you're running in proxy-mode (using mimir-distributor as reference):

```bash
❯ istioctl --context kind-lgtm-remote proxy-config endpoint $(kubectl --context kind-lgtm-remote get pod -l name=app -n tns -o name | sed 's|.*/||').tns | grep mimir-distributor
192.168.97.249:15443                                    HEALTHY     OK                outbound|8080||mimir-distributor.mimir.svc.cluster.local
192.168.97.249:15443                                    HEALTHY     OK                outbound|9095||mimir-distributor.mimir.svc.cluster.local

❯ kubectl get svc -n istio-system lgtm-gateway --context kind-lgtm-central
NAME           TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)                                                           AGE
lgtm-gateway   LoadBalancer   10.12.201.116   192.168.97.249   15021:31614/TCP,15443:32226/TCP,15012:32733/TCP,15017:30681/TCP   21m

❯ kubectl --context kind-lgtm-remote exec -it -n tns $(kubectl --context kind-lgtm-remote get pod -n tns -l name=app -o name) -- nslookup mimir-distributor.mimir.svc.cluster.local
Name:      mimir-distributor.mimir.svc.cluster.local
Address 1: 10.12.92.57

❯ kubectl --context kind-lgtm-central get svc -n mimir mimir-distributor
NAME                TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)             AGE
mimir-distributor   ClusterIP   10.12.92.57   <none>        8080/TCP,9095/TCP   17m

❯ kubectl --context kind-lgtm-central get pod -n mimir -l app.kubernetes.io/component=distributor -o wide
NAME                                 READY   STATUS    RESTARTS   AGE   IP           NODE                   NOMINATED NODE   READINESS GATES
mimir-distributor-78b6d8b96b-72cmn   2/2     Running   0          15m   10.11.3.14   lgtm-central-worker2   <none>           <none>
mimir-distributor-78b6d8b96b-k8w6g   2/2     Running   0          15m   10.11.2.59   lgtm-central-worker    <none>           <none>
```

If you're running in ambient-mode:

```bash
❯ kubectl get gatewayclass
NAME              CONTROLLER                     ACCEPTED   AGE
istio             istio.io/gateway-controller    True       4m30s
istio-east-west   istio.io/eastwest-controller   True       4m30s
istio-remote      istio.io/unmanaged-gateway     True       4m30s
istio-waypoint    istio.io/mesh-controller       True       4m30s

❯ kubectl get gateway -A
NAMESPACE      NAME                    CLASS             ADDRESS          PROGRAMMED   AGE
istio-system   istio-eastwestgateway   istio-east-west   192.168.97.248   True         4m13s
```

The following uses the mimir-distributor as reference:

```bash
❯ istioctl zc service --service-namespace mimir --context kind-lgtm-remote
NAMESPACE SERVICE NAME      SERVICE VIP  WAYPOINT ENDPOINTS
mimir     mimir-distributor 10.12.81.157 None     1/1

❯ istioctl zc workload --workload-namespace mimir -o json --context kind-lgtm-remote
[
    {
        "uid": "lgtm-central/SplitHorizonWorkload/istio-system/istio-eastwestgateway/192.168.97.249/mimir/mimir-distributor.mimir.svc.cluster.local",
        "workloadIps": [],
        "networkGateway": {
            "destination": "lgtm-central/192.168.97.249"
        },
        "protocol": "HBONE",
        "name": "lgtm-central/SplitHorizonWorkload/istio-system/istio-eastwestgateway/192.168.97.249/mimir/mimir-distributor.mimir.svc.cluster.local",
        "namespace": "mimir",
        "serviceAccount": "default",
        "workloadName": "",
        "workloadType": "pod",
        "canonicalName": "",
        "canonicalRevision": "",
        "clusterId": "central",
        "trustDomain": "cluster.local",
        "locality": {},
        "node": "",
        "network": "lgtm-central",
        "status": "Healthy",
        "hostname": "",
        "capacity": 2,
        "applicationTunnel": {
            "protocol": ""
        }
    }
]

❯ istioctl zc services --service-namespace mimir -o json --context kind-lgtm-remote
[
    {
        "name": "mimir-distributor",
        "namespace": "mimir",
        "hostname": "mimir-distributor.mimir.svc.cluster.local",
        "vips": [
            "lgtm-central/10.12.81.157"
        ],
        "ports": {
            "8080": 0,
            "9095": 0
        },
        "endpoints": {
            "lgtm-central/SplitHorizonWorkload/istio-system/istio-eastwestgateway/192.168.97.249/mimir/mimir-distributor.mimir.svc.cluster.local": {
                "workloadUid": "lgtm-central/SplitHorizonWorkload/istio-system/istio-eastwestgateway/192.168.97.249/mimir/mimir-distributor.mimir.svc.cluster.local",
                "service": "",
                "port": {
                    "8080": 0,
                    "9095": 0
                }
            }
        },
        "subjectAltNames": [
            "spiffe://cluster.local/ns/mimir/sa/mimir-sa"
        ],
        "ipFamilies": "IPv4"
    }
]
```

> **WARNING**: there are DNS issues for cross-cluster resolution, even with Cilium disabled.

```bash
❯ kubectl --context kind-lgtm-remote exec -it -n tns $(kubectl --context kind-lgtm-remote get pod -n tns -l name=app -o name) -- nslookup mimir-distributor.mimir.svc.cluster.local
nslookup: can't resolve '(null)': Name does not resolve

nslookup: can't resolve 'mimir-distributor.mimir.svc.cluster.local': Name does not resolve
command terminated with exit code 1
```

### Cilium ClusterMesh

The `cilium` CLI can help to verify if the inter-cluster communication is working. From each context, you can run the following:

```bash
cilium clustermesh status --context ${ctx}
```

The following shows how it looks like when having both remote clusters deployed:

```bash
for ctx in central remote remote-otel; do
  echo "Checking cluster ${ctx}"
  cilium clustermesh status --context kind-lgtm-${ctx}
  echo
done
```

The result is:

```
Checking cluster central
✅ Service "clustermesh-apiserver" of type "LoadBalancer" found
✅ Cluster access information is available:
  - 172.19.255.249:2379
✅ Deployment clustermesh-apiserver is ready
✅ All 4 nodes are connected to all clusters [min:2 / avg:2.0 / max:2]
🔌 Cluster Connections:
  - lgtm-remote: 4/4 configured, 4/4 connected
  - lgtm-remote-otel: 4/4 configured, 4/4 connected
🔀 Global services: [ min:0 / avg:0.0 / max:0 ]

Checking cluster remote
✅ Service "clustermesh-apiserver" of type "LoadBalancer" found
✅ Cluster access information is available:
  - 172.19.255.241:2379
✅ Deployment clustermesh-apiserver is ready
✅ All 2 nodes are connected to all clusters [min:1 / avg:1.0 / max:1]
🔌 Cluster Connections:
  - lgtm-central: 2/2 configured, 2/2 connected
🔀 Global services: [ min:4 / avg:4.0 / max:4 ]

Checking cluster remote-otel
✅ Service "clustermesh-apiserver" of type "LoadBalancer" found
✅ Cluster access information is available:
  - 172.19.255.233:2379
✅ Deployment clustermesh-apiserver is ready
✅ All 2 nodes are connected to all clusters [min:1 / avg:1.0 / max:1]
🔌 Cluster Connections:
  - lgtm-central: 2/2 configured, 2/2 connected
🔀 Global services: [ min:4 / avg:4.0 / max:4 ]
```

### LGTM Stack

If you're running on Linux or macOS with OrbStack, you should add an entry to `/etc/hosts` for `grafana.example.com` pointing to the IP that the Ingress will get on the Central cluster (the script will tell you that IP), or:

```bash
kubectl get svc --context kind-lgtm-central -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

If you're using Docker for Desktop on macOS, I created a script to deploy HAProxy which allows you to access the Ingress Service via localhost:

```bash
./deploy-proxy.sh
```

In that case, use `127.0.0.1` when modifying `/etc/hosts` instead of the LB IP.

Then, access the Grafana WebUI available at `https://grafana.example.com` and accept the warning as the site uses a certificate signed by a self-signed CA.

The password for the `admin` account is defined in [values-prometheus-central.yaml](./values-prometheus-central.yaml) (i.e., `Adm1nAdm1n`). From the Explore tab, you should be able to access the data collected locally and received from the remote location using the data sources described initially.

Within the [dashboards](./dashboards/) subdirectory, you should find a sample dashboard for the TNS App that you can use to visualize metrics from more locations based on the metrics stored in the central location. If you check the logs for that application (`tns` namespace), you can visualize the remote logs stored on the central Loki and the traces.

### Troubleshooting

For some reason, sometimes the Ingress controller doesn't correctly apply the Ingress resource, and after updating `/etc/hosts`, the Grafana UI is still unreachable. If that happens, the easiest solution is to restart the Ingress controller:

```bash
kubectl rollout restart deployment -n ingress-nginx ingress-nginx-controller --context kind-lgtm-central
```

## Shutdown

```bash
kind delete cluster --name lgtm-central
kind delete cluster --name lgtm-remote
kind delete cluster --name lgtm-remote-otel
```

Or,

```bash
kind delete clusters --all
```

> **Warning**: Be careful with the above command if you have clusters you don't want to remove.

If you started the HAProxy:

```bash
docker stop haproxy
docker rm haproxy
```
