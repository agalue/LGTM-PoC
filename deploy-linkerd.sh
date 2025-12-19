#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "helm" "kubectl"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CERT_ISSUER_ID=${CERT_ISSUER_ID:-}
SERVICE_MESH_HA=${SERVICE_MESH_HA:-no}
SERVICE_MESH_TRACES_ENABLED=${SERVICE_MESH_TRACES_ENABLED:-no}
LINKERD_VIZ_ENABLED=${LINKERD_VIZ_ENABLED:-yes}
LINKERD_REPO=${LINKERD_REPO:-edge} # Either stable (2.14) or edge
LINKERD_REMOTE=${LINKERD_REMOTE:-false} # true for remote clusters, false for central cluster

REPOSITORY_NAME="linkerd"
if [[ "$LINKERD_REPO" == "edge" ]]; then
  REPOSITORY_NAME="linkerd-edge"
fi

if [[ "$CERT_ISSUER_ID" == "" ]]; then
  echo "CERT_ISSUER_ID env-var required"
  exit 1
fi

CERT_EXPIRY_FILE=cert-expiry-date.txt
if [ ! -f $CERT_EXPIRY_FILE ]; then
  echo "$CERT_EXPIRY_FILE not found; please run deploy-certs.sh"
  exit 1
fi
CERT_EXPIRY_DATE=$(cat $CERT_EXPIRY_FILE)

if [ ! -f "linkerd-ca.crt" ]; then
  echo "linkerd-ca.crt not found; please run deploy-certs.sh"
  exit 1
fi

if [ ! -f "linkerd-$CERT_ISSUER_ID.crt" ]; then
  echo "linkerd-$CERT_ISSUER_ID.crt not found; please run deploy-certs.sh"
  exit 1
fi

echo "Update kube-system namespace"
kubectl label ns kube-system config.linkerd.io/admission-webhooks=disabled --overwrite

echo "Deploying Linkerd CRDs"
helm upgrade --install linkerd-crds $REPOSITORY_NAME/linkerd-crds \
  --namespace linkerd --create-namespace

echo "Deploying Linkerd"
helm_values_args=("-f" "values-linkerd.yaml")
if [[ "$SERVICE_MESH_HA" == "yes" ]]; then
  helm_values_args+=("-f" "values-linkerd-ha.yaml")
fi
helm upgrade --install linkerd-control-plane $REPOSITORY_NAME/linkerd-control-plane \
  --namespace linkerd \
  --set-file identityTrustAnchorsPEM=linkerd-ca.crt \
  --set-file identity.issuer.tls.crtPEM=linkerd-$CERT_ISSUER_ID.crt \
  --set-file identity.issuer.tls.keyPEM=linkerd-$CERT_ISSUER_ID.key \
  --set identity.issuer.crtExpiry=$CERT_EXPIRY_DATE \
  ${helm_values_args[@]} \
  --wait

echo "Update PodMonitor resources"
for obj in $(kubectl get podmonitor -n linkerd -o name); do
  kubectl label -n linkerd $obj release=monitor --overwrite
done

# Requires Prometheus
if [[ "$LINKERD_VIZ_ENABLED" == "yes" ]]; then
  echo "Deploying Linkerd-Viz"
  helm upgrade --install linkerd-viz $REPOSITORY_NAME/linkerd-viz \
  --namespace linkerd-viz --create-namespace \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set prometheusUrl=http://monitor-prometheus.observability.svc:9090 \
  --set dashboard.enforcedHostRegexp=".*" \
  --wait
fi

# Requires Grafana Alloy or Tempo
if [[ "$SERVICE_MESH_TRACES_ENABLED" == "yes" ]]; then
  echo "Deploying Linkerd-Jaeger via Grafana Alloy"
  helm upgrade --install linkerd-jaeger $REPOSITORY_NAME/linkerd-jaeger \
  --namespace linkerd-jaeger --create-namespace \
  --set collector.enabled=false \
  --set jaeger.enabled=false \
  --set webhook.collectorSvcAddr=grafana-alloy.observability.svc:55678 \
  --set webhook.collectorSvcAccount=grafana-alloy \
  --wait
fi

echo "Deploying Linkerd Multicluster"
helm_multicluster_args=(" ")
if [[ "$LINKERD_REMOTE" == "true" ]]; then
  helm_multicluster_args+=("-f" "values-linkerd-mc-remote.yaml")
fi

helm upgrade --install linkerd-multicluster $REPOSITORY_NAME/linkerd-multicluster \
  --namespace linkerd-multicluster --create-namespace \
  ${helm_multicluster_args[@]} \
  --wait
