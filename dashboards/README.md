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

> *WARNING:* Consider the following a work in progress.

Some of the [original](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-demo/grafana-dashboards) dashboards assume a local Prometheus data source as the default, and others use an OpenSearch data source, which won't work when deploying them at the central location. This is mainly because the OTEL Demo deploys Prometheus and Grafana by default, but we're not using those instances in this PoC.

The following deploys adjusted versions of the dashboards from the OTEL Demo Helm Chart to work on this environment:

```bash
kubectl --context kind-lgtm-central create cm otel-demo -n observability \
  --from-file=otel-demo.json \
  --from-file=otel-spanmetrics.json \
  --from-file=otel-collector.json \
  --from-file=otel-collector-flow.json
kubectl --context kind-lgtm-central label cm otel-demo -n observability grafana_dashboard=1 
```
