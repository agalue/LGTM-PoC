#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

CENTRAL=${CENTRAL-lgtm-central}
CONTEXT=${CONTEXT-lgtm-remote}
CILIUM_CLUSTER_MESH_ENABLED=${CILIUM_CLUSTER_MESH_ENABLED-no} # no for Linkerd or Istio, yes for Cilium CM
ISTIO_ENABLED=${ISTIO_ENABLED-no} # no for Linkerd, yes for Istio

CENTRAL_CTX=kind-${CENTRAL}
REMOTE_CTX=kind-${CONTEXT}

# Configuration files designed for Linkerd MC that requires alterations to work with Istio or Cilium CM
FILES=${FILES:-}

# Application Namespace
APP_NS=${APP_NS:-}

patch_files() {
  for FILE in "${FILES[@]}"; do
    sed "s/-${CENTRAL}//" "${FILE}" > "/tmp/${FILE}"
  done
}

cp "${FILES[@]}" /tmp
if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" == "yes" ]]; then
  patch_files
else
  if [[ "${ISTIO_ENABLED}" == "yes" ]]; then
    patch_files
    echo "Deploying Istio"
    . deploy-istio.sh
  else
    echo "Deploying Linkerd"
    . deploy-linkerd.sh
  fi
fi

echo "Setting up namespaces"
for ns in observability mimir tempo loki $APP_NS; do
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    istio-injection: enabled
  annotations:
    linkerd.io/inject: enabled
EOF
done

echo "Creating link from ${REMOTE_CTX} to ${CENTRAL_CTX}"
if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" == "yes" ]]; then
  cilium clustermesh connect --context ${REMOTE_CTX} --destination-context ${CENTRAL_CTX}

  # Create copies of the global services in the remote cluster
  declare -a SERVICES=( \
    "service/mimir-distributor -n mimir" \
    "service/tempo-distributor -n tempo" \
    "service/loki-write -n loki" \
    "service/monitor-alertmanager -n observability"
  )
  for SVC in "${SERVICES[@]}"; do
    kubectl --context ${CENTRAL_CTX} get ${SVC} -o yaml \
      | sed -E '/(resourceVersion|uid|creationTimestamp):/d' \
      | sed '/clusterIP:/,+2d' | sed '/^status:/,+2d' \
      | sed '/service.cilium.io\/shared/s/true/false/' \
      | kubectl --context ${REMOTE_CTX} apply -f -
  done
else
  # The following is required when using Kind/Docker without apiServerAddress on Kind config.
  API_SERVER=$(kubectl get node --context ${CENTRAL_CTX} -l node-role.kubernetes.io/control-plane -o json \
    | jq -r '.items[] | .status.addresses[] | select(.type=="InternalIP") | .address')
  if [[ "${ISTIO_ENABLED}" == "yes" ]]; then
    istioctl create-remote-secret \
      --context=${CENTRAL_CTX} \
      --server https://${API_SERVER}:6443 \
      --name=central | \
      kubectl apply --context=${REMOTE_CTX} -f -
  else
    linkerd mc link --context ${CENTRAL_CTX} --cluster-name ${CENTRAL} \
      --api-server-address="https://${API_SERVER}:6443" \
      | kubectl apply --context ${REMOTE_CTX} -f -
    fi
fi
