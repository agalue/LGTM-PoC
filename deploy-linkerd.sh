#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "helm" "kubectl"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CERT_ISSUER_ID=${CERT_ISSUER_ID-}
DOMAIN=${DOMAIN-}
LINKERD_HA=${LINKERD_HA-no}
LINKERD_VIZ_ENABLED=${LINKERD_VIZ_ENABLED-yes}
LINKERD_JAEGER_ENABLED=${LINKERD_JAEGER_ENABLED-yes}
LINKERD_REPO=${LINKERD_REPO-stable} # Either stable (2.14) or edge

REPOSITORY_NAME="linkerd"
if [[ "$LINKERD_REPO" == "edge" ]]; then
  REPOSITORY_NAME="linkerd-edge"
fi

if [[ "$CERT_ISSUER_ID" == "" ]]; then
  echo "CERT_ISSUER_ID env-var required"
  exit 1
fi

if [[ "$DOMAIN" == "" ]]; then
  echo "DOMAIN env-var required"
  exit 1
fi

CERT_EXPIRY_FILE=cert-expiry-date.txt
if [ ! -f $CERT_EXPIRY_FILE ]; then
  echo "$CERT_EXPIRY_FILE not found; please run deploy-certs.sh"
  exit 1
fi
CERT_EXPIRY_DATE=$(cat $CERT_EXPIRY_FILE)

if [ ! -f ca.crt ]; then
  echo "ca.crt not found; please run deploy-certs.sh"
  exit 1
fi

if [ ! -f "$CERT_ISSUER_ID.crt" ]; then
  echo "$CERT_ISSUER_ID.crt not found; please run deploy-certs.sh"
  exit 1
fi

echo "Update kube-system namespace"
kubectl label ns kube-system config.linkerd.io/admission-webhooks=disabled --overwrite

echo "Deploying Linkerd CRDs"
helm upgrade --install linkerd-crds $REPOSITORY_NAME/linkerd-crds \
  --namespace linkerd --create-namespace

echo "Deploying Linkerd"
helm_values_args=("-f" "values-linkerd.yaml")
if [[ "$LINKERD_HA" == "yes" ]]; then
  helm_values_args+=("-f" "values-linkerd-ha.yaml")
fi
helm upgrade --install linkerd-control-plane $REPOSITORY_NAME/linkerd-control-plane \
  --namespace linkerd \
  --set clusterDomain=$DOMAIN \
  --set identityTrustDomain=$DOMAIN \
  --set-file identityTrustAnchorsPEM=ca.crt \
  --set-file identity.issuer.tls.crtPEM=$CERT_ISSUER_ID.crt \
  --set-file identity.issuer.tls.keyPEM=$CERT_ISSUER_ID.key \
  --set identity.issuer.crtExpiry=$CERT_EXPIRY_DATE \
  ${helm_values_args[@]} \
  --wait

echo "Update PodMonitor resources"
for obj in "controller" "proxy" "service-mirror"; do
  kubectl label -n linkerd podmonitor/linkerd-$obj release=monitor --overwrite
done

# Requires Prometheus
if [[ "$LINKERD_VIZ_ENABLED" == "yes" ]]; then
  echo "Deploying Linkerd-Viz"
  helm upgrade --install linkerd-viz $REPOSITORY_NAME/linkerd-viz \
  --namespace linkerd-viz --create-namespace \
  --set clusterDomain=$DOMAIN \
  --set identityTrustDomain=$DOMAIN \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set prometheusUrl=http://monitor-prometheus.observability.svc:9090 \
  --set dashboard.enforcedHostRegexp=".*" \
  --wait
fi

# Requires Grafana Agent
if [[ "$LINKERD_JAEGER_ENABLED" == "yes" ]]; then
  echo "Deploying Linkerd-Jaeger via Grafana Agent"
  helm upgrade --install linkerd-jaeger $REPOSITORY_NAME/linkerd-jaeger \
  --namespace linkerd-jaeger --create-namespace \
  --set clusterDomain=$DOMAIN \
  --set collector.enabled=false \
  --set jaeger.enabled=false \
  --set webhook.collectorSvcAddr=grafana-agent.observability.svc:55678 \
  --set webhook.collectorSvcAccount=grafana-agent \
  --wait
fi

echo "Deploying Linkerd Multicluster"
helm upgrade --install linkerd-multicluster $REPOSITORY_NAME/linkerd-multicluster \
  --namespace linkerd-multicluster --create-namespace \
  --set identityTrustDomain=$DOMAIN \
  --wait
