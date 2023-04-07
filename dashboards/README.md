# Dashboards

## Mimir

Ensure you have [Docker](https://www.docker.com/) installed and running on your machine to compile Mimir's dashboards. All the dependencies to build anything related to Mimir exist on a custom Docker Image to avoid installing and configuring the dependencies locally.

```bash
git clone https://github.com/grafana/mimir.git
cd mimir
sed -i -r "/singleBinary/s/false/true/" operations/mimir-mixin/config.libsonnet
make build-mixin
```

> The operator requires having Docker up and running.

The dashboards are located at `operations/mimir-mixin-compiled/dashboards/`.

The reason for using `singleBinary` mode is that, by default, all metrics should have a label called `cluster`, assuming you could have metrics for multiple Mimir instances, but in our case, we have only one.

For convenience the updated dashboards are copied into this repository under the `mimir` sub-directory.

To deploy them to the central cluster:

```bash
for file in mimir/*.json; do
  name=$(echo $file | sed 's/^mimir\///' | sed 's/\.json//')
  echo "Creating dashboard $name"
  kubectl --context lgtm-central create cm $name -n observability --from-file=$file
  kubectl --context lgtm-central label cm $name -n observability grafana_dashboard=1 release=monitor
done
```

## Loki

When you install Loki via its Helm chart and you have monitoring enabled, the dashboards are automatically deployed.

## Tempo

There are dashboards for Tempo, but they need some rework to avoid depending on the `cluster` label, as the `singleBinary` mode is unavailable.

For that reason, there are no dashboards available.

## TNS Application

The following deploys a sample dashboard for the TNS application:

```bash
kubectl --context lgtm-central create cm tns -n observability --from-file=tns.json
kubectl --context lgtm-central label cm tns -n observability grafana_dashboard=1 release=monitor
```
