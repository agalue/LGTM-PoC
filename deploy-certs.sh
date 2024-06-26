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

step certificate create \
  root.linkerd.cluster.local \
  ca.crt ca.key \
  --profile root-ca \
  --no-password --insecure \
  --force

step certificate create \
  identity.linkerd.lgtm-central.cluster.local \
  issuer-central.crt issuer-central.key \
  --profile intermediate-ca \
  --not-after ${CERT_EXPIRY_HOURS}h --no-password --insecure \
  --ca ca.crt --ca-key ca.key \
  --force

step certificate create \
  identity.linkerd.lgtm-remote.cluster.local \
  issuer-remote.crt issuer-remote.key \
  --profile intermediate-ca \
  --not-after ${CERT_EXPIRY_HOURS}h --no-password --insecure \
  --ca ca.crt --ca-key ca.key \
  --force

step certificate create \
  identity.linkerd.lgtm-otel.cluster.local \
  issuer-otel.crt issuer-otel.key \
  --profile intermediate-ca \
  --not-after ${CERT_EXPIRY_HOURS}h --no-password --insecure \
  --ca ca.crt --ca-key ca.key \
  --force

step certificate create \
  root.cilium.io \
  cilium-ca.crt cilium-ca.key \
  --profile root-ca \
  --no-password --insecure \
  --force

echo ${CERT_EXPIRY_DATE} > cert-expiry-date.txt