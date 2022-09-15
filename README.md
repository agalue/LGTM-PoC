# LGTM PoC

In the Kubernetes world, the best way to monitor the cluster and everything running on it are via Prometheus. Microservices, especially those written in Go, could expose metrics in Prometheus format, and there is a vast collection of exporters for those applications that don't natively. For that reason, Mimir is the best way to consolidate metrics from multiple Kubernetes clusters (and the applications running on each of them).

Loki is drastically easier to deploy and manage than the traditional ELK stack, which is why I consider it the best log aggregation solution. For similar reasons, Tempo for traces.

## Architecture

![Architecture](architecture-0.png)

We will have *two* Kubernetes clusters, one with the LGTM Stack exposing Grafana via Ingress (`lgtm-central`), and another with a sample application, generating metrics, logs, and traces (`lgtm-remote`).

As Zero Trust is becoming more important nowadays, we'll use Linkerd to secure the communication within each cluster and the communication between the clusters, which gives us the ability to have a secure channel without implementing authentication, authorization, and encryption on our own.

![Architecture](architecture-1.png)

We will use Minikube for the clusters, and as the Linkerd Gateway for Multi-Cluster requires a Load Balancer service, we will enable and configure the MetalLB plugin on Minikube, and we'll have different Cluster Domain.

For MetalLB, the Central cluster will use segment `x.x.x.201-210`, and the Remote cluster will employ `x.x.x.211-220` for the Public IPs extracted from the Minikube IP on each case.

The Multi-Cluster Link is originated on the Remote Cluster, targeting the Central Cluster, meaning the Service Mirror Controller lives on the Remote Cluster.

## Requirements

* [Minikube](https://minikube.sigs.k8s.io/)
* [Kubectl](https://kubernetes.io/docs/tasks/tools/)
* [Helm](https://helm.sh/)
* [Step CLI](https://smallstep.com/docs/step-cli)
* [Linkerd CLI](https://linkerd.io/2.12/getting-started/#step-1-install-the-cli)

The solution has been designed and tested on macOS. You might need to change the scripts to run them on a different operating system.

## Start

* Create anchor and issuer certificates for Linkerd:

```bash
./deploy-certs.sh
```

* Deploy Central Cluster with LGTM stack:

```bash
./deploy-central.sh
```

* Deploy Remote Cluster with sample application linked to the Central Cluster:

```bash
./deploy-remote.sh
```

You should add an entry to `/etc/hosts` for `grafana.example.com` pointing to the IP that the Ingress will get on the Central cluster (the script will tell you that IP).

## Shutdown

```bash
minikube delete -p lgtm-central
minikube delete -p lgtm-remote
```
