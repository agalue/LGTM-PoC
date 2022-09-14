#!/bin/bash

set -e

for cmd in "helm" "linkerd"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CERT_ISSUER_ID=${CERT_ISSUER_ID-}
DOMAIN=${DOMAIN-}

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

echo "Deploying Linkerd CRDs"
helm upgrade --install linkerd-crds linkerd/linkerd-crds \
  --namespace linkerd --create-namespace

echo "Deploying Linkerd"
helm upgrade --install linkerd-control-plane linkerd/linkerd-control-plane \
  --namespace linkerd \
  --set clusterDomain=$DOMAIN \
  --set identityTrustDomain=$DOMAIN \
  --set-file identityTrustAnchorsPEM=ca.crt \
  --set-file identity.issuer.tls.crtPEM=$CERT_ISSUER_ID.crt \
  --set-file identity.issuer.tls.keyPEM=$CERT_ISSUER_ID.key \
  --set identity.issuer.crtExpiry=$CERT_EXPIRY_DATE \
  -f values-linkerd.yaml \
  --wait

echo "Deploying Linkerd-Viz"
helm upgrade --install linkerd-viz linkerd/linkerd-viz \
  --namespace linkerd-viz --create-namespace \
  --set clusterDomain=$DOMAIN \
  --set identityTrustDomain=$DOMAIN \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set prometheusUrl=http://monitor-prometheus.observability.svc:9090 \
  --wait

echo "Deploying Linkerd Multicluster"
linkerd mc install | kubectl apply -f -
