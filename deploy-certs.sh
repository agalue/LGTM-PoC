#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

CERT_EXPIRY_HOURS=${CERT_EXPIRY_HOURS-8760}
if [[ $OSTYPE == 'darwin'* ]]; then
  CERT_EXPIRY_DATE=$(date -u -v+${CERT_EXPIRY_HOURS}H +"%Y-%m-%dT%H:%M:%SZ") # For macOS Only
else
  CERT_EXPIRY_DATE=$(date -d "${CERT_EXPIRY_HOURS}hours" +"%Y-%m-%dT%H:%M:%SZ") # For Linux Only
fi

type step >/dev/null 2>&1 || { echo >&2 "step required but it's not installed; aborting."; exit 1; }

# Linkerd

step certificate create \
  root.linkerd.cluster.local \
  linkerd-ca.crt linkerd-ca.key \
  --profile root-ca \
  --no-password --insecure \
  --force

for CLUSTER in "central" "remote" "otel"; do
  step certificate create \
    identity.linkerd.lgtm-${CLUSTER}.cluster.local \
    linkerd-issuer-${CLUSTER}.crt linkerd-issuer-${CLUSTER}.key \
    --profile intermediate-ca \
    --not-after ${CERT_EXPIRY_HOURS}h --no-password --insecure \
    --ca linkerd-ca.crt --ca-key linkerd-ca.key \
    --force
done

# Cilium

step certificate create \
  root.cilium.io \
  cilium-ca.crt cilium-ca.key \
  --profile root-ca \
  --no-password --insecure \
  --force

# Istio

step certificate create \
  "Istio Root CA" \
  istio-root-ca.crt istio-root-ca.key \
  --profile root-ca \
  --no-password --insecure \
  --force

for CLUSTER in "central" "remote" "otel"; do
  step certificate create \
    "Istio ${CLUSTER} cluster" \
    istio-issuer-${CLUSTER}.crt istio-issuer-${CLUSTER}.key \
    --profile intermediate-ca \
    --no-password --insecure \
    --ca istio-root-ca.crt --ca-key istio-root-ca.key \
    --force
  cat istio-issuer-${CLUSTER}.crt istio-root-ca.crt > istio-issuer-${CLUSTER}-chain.crt
done

echo ${CERT_EXPIRY_DATE} > cert-expiry-date.txt