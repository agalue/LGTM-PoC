# Dashboards

## Mimir

When you install Mimir via its Helm chart and you have monitoring enabled (see values file), the dashboards are automatically deployed.

## Loki

When you install Loki via its Helm chart and you have monitoring enabled (see values file), the dashboards are automatically deployed.

## Tempo

The Helm chart doesn't provide dashboards by default like Mimir or Loki, so the following helps to deploy the generated dashboards from Tempo's source code (see [here](https://github.com/grafana/tempo/tree/main/operations/tempo-mixin-compiled)):

```bash
tempoUrl="https://raw.githubusercontent.com/grafana/tempo/main/operations/tempo-mixin-compiled"
for id in "rules" "alerts"; do
  cat <<EOF > tempo-${id}.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: tempo-${id}
  namespace: tempo
  labels:
    release: monitor
spec:
EOF
  wget -qO- ${tempoUrl}/${id}.yaml | sed 's/^/  /' >> tempo-${id}.yaml
  kubectl apply -f tempo-${id}.yaml
done
for id in "operational" "reads" "resources" "rollout-progress" "tenants" "writes"; do
  dashboard="tempo-${id}.json"
  wget --quiet ${tempoUrl}/dashboards/${dashboard}
  kubectl create cm dashboard-${id} -n tempo --from-file=${dashboard}
  kubectl label cm dashboard-${id} -n tempo grafana_dashboard=1
done
rm -f tempo-*.*
```

## TNS Application

The following deploys a sample dashboard for the TNS application:

```bash
kubectl --context kind-lgtm-central create cm tns -n observability --from-file=tns.json
kubectl --context kind-lgtm-central label cm tns -n observability grafana_dashboard=1 release=monitor
```

> **Note**: The TNS dashboard works with both the traditional stack (`lgtm-remote`) and unified Alloy deployment (`lgtm-remote-alloy`) since Grafana Alloy is fully compatible with Prometheus metrics. Simply switch between the `Mimir Remote TNS` and `Mimir Remote Alloy` data sources in Grafana.

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
