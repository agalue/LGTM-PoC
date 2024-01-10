# Dashboards

## Mimir

When you install Mimir via its Helm chart and you have monitoring enabled (see values file), the dashboards are automatically deployed.

## Loki

When you install Loki via its Helm chart and you have monitoring enabled (see values file), the dashboards are automatically deployed.

## Tempo

There are dashboards for Tempo, but they need some rework to avoid depending on the `cluster` label, as the `singleBinary` mode is unavailable.

For that reason, there are no dashboards available.

## TNS Application

The following deploys a sample dashboard for the TNS application:

```bash
kubectl --context lgtm-central create cm tns -n observability --from-file=tns.json
kubectl --context lgtm-central label cm tns -n observability grafana_dashboard=1 release=monitor
```

