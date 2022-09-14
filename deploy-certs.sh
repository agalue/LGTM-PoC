#!/bin/bash

set -e

CERT_EXPIRY_HOURS=8760
CERT_EXPIRY_DATE=$(date -u -v+${CERT_EXPIRY_HOURS}H +"%Y-%m-%dT%H:%M:%SZ") # For macOS Only

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

echo ${CERT_EXPIRY_DATE} > cert-expiry-date.txt