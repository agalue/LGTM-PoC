#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

if [[ -z "${NAMESPACES}" ]]; then
  echo >&2 "Error: NAMESPACES environment variable is required"
  exit 1
fi

echo "Setting up namespaces: ${NAMESPACES}"

# Create namespaces with appropriate mesh configuration
for ns in ${NAMESPACES}; do
  if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" == "yes" ]]; then
    # Cilium ClusterMesh doesn't require mesh labels/annotations
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
EOF
  elif [[ "${ISTIO_ENABLED}" == "yes" ]]; then
    # Istio uses labels
    MESH_LABEL="istio-injection: enabled"
    if [[ "$ISTIO_PROFILE" == "ambient" ]]; then
      MESH_LABEL="istio.io/dataplane-mode: ambient"
    fi
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    $MESH_LABEL
EOF
  else
    # Linkerd uses annotations
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  annotations:
    linkerd.io/inject: enabled
EOF
  fi
done
