# Dashboards

## Mimir

When you install Mimir via its Helm chart and you have monitoring enabled (see values file), the dashboards are automatically deployed.

## Loki

When you install Loki via its Helm chart and you have monitoring enabled (see values file), the dashboards are automatically deployed.

## Tempo

There are dashboards for Tempo, but they need some rework to avoid depending on the `cluster` label, as the `singleBinary` mode is unavailable.

For that reason, there are no dashboards deployed on this PoC.

## TNS Application

The following deploys a sample dashboard for the TNS application:

```bash
kubectl --context kind-lgtm-central create cm tns -n observability --from-file=tns.json
kubectl --context kind-lgtm-central label cm tns -n observability grafana_dashboard=1 release=monitor
```

## OTEL Demo Application

> *WARNING*: Some of the dashboards assume the presence of a local Prometheus data source as the default, and others use an OpenSearch data source, which won't work when deploying them at the central location. You would have to adjust the content of the affected dashboards to use them.

The following deploys the dashboards from the OTEL Demo Helm Chart:

```bash
base_url="https://raw.githubusercontent.com/open-telemetry/opentelemetry-helm-charts/main/charts/opentelemetry-demo/grafana-dashboards/"

dashboards=(
  "demo-dashboard.json" \
  "opentelemetry-collector-data-flow.json" \
  "opentelemetry-collector.json" \
  "spanmetrics-dashboard.json" \
)

arguments=()
for dashboard in ${dashboards[@]}; do
  wget -O ${dashboard} ${base_url}${dashboard}
  arguments+="--from-file=${dashboard}"
done

kubectl --context kind-lgtm-central create cm otel-demo -n observability ${arguments[@]}
kubectl --context kind-lgtm-central label cm otel-demo -n observability grafana_dashboard=1 release=monitor
```

> Doing that manually is because we're not deploying Grafana with the OTEL Demo App. Instead, we have it on the central cluster.
