#!/bin/bash

# This script sets up service mesh connectivity between clusters
# For Linkerd: Requires edge-25.12.x or later (version 2.18.x+) for new multicluster approach
# The new approach uses 'linkerd mc link-gen' + Helm chart instead of deprecated 'linkerd mc link'

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# Check for required tools
for cmd in "kubectl" "jq"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CENTRAL=${CENTRAL-lgtm-central}
CONTEXT=${CONTEXT-lgtm-remote}
CILIUM_CLUSTER_MESH_ENABLED=${CILIUM_CLUSTER_MESH_ENABLED-no} # no for Linkerd or Istio, yes for Cilium CM
ISTIO_ENABLED=${ISTIO_ENABLED-no} # no for Linkerd, yes for Istio
ISTIO_PROFILE=${ISTIO_PROFILE-default} # default or ambient
CENTRAL_CTX=kind-${CENTRAL}
REMOTE_CTX=kind-${CONTEXT}
LINKERD_REMOTE=true

# Check for mesh-specific required tools
if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" == "yes" ]]; then
  type cilium >/dev/null 2>&1 || { echo >&2 "cilium required but it's not installed; aborting."; exit 1; }
elif [[ "${ISTIO_ENABLED}" == "yes" ]]; then
  type istioctl >/dev/null 2>&1 || { echo >&2 "istioctl required but it's not installed; aborting."; exit 1; }
else
  type linkerd >/dev/null 2>&1 || { echo >&2 "linkerd required but it's not installed; aborting."; exit 1; }
fi
FILES=${FILES:-}

# Application Namespace
APP_NS=${APP_NS:-}

# Patches configuration files for Istio/Cilium ClusterMesh by removing Linkerd's cluster suffix
# Linkerd: mimir-distributor-lgtm-central.mimir.svc (mirrored service with cluster suffix)
# Istio/Cilium: mimir-distributor.mimir.svc (original service name, no suffix)
# This function transforms Linkerd service URLs to work with Istio and Cilium ClusterMesh
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

NAMESPACES="observability mimir tempo loki $APP_NS"
. deploy-namespaces.sh

declare -a SERVICES=( \
  "service/mimir-distributor -n mimir" \
  "service/tempo-distributor -n tempo" \
  "service/loki-write -n loki" \
  "service/monitor-alertmanager -n observability"
)

echo "Creating link from ${REMOTE_CTX} to ${CENTRAL_CTX}"
if [[ "${CILIUM_CLUSTER_MESH_ENABLED}" == "yes" ]]; then
  cilium clustermesh connect --context ${REMOTE_CTX} --destination-context ${CENTRAL_CTX}

  # Create copies of the global services in the remote cluster
  for SVC in "${SERVICES[@]}"; do
    kubectl --context ${CENTRAL_CTX} get ${SVC} -o yaml \
      | sed -E '/(resourceVersion|uid|creationTimestamp):/d' \
      | sed '/clusterIP:/,+2d' | sed '/^status:/,+2d' \
      | sed '/service.cilium.io\/shared/s/true/false/' \
      | kubectl --context ${REMOTE_CTX} apply -f -
  done
else
  # The following is required when using Kind/Docker without apiServerAddress on Kind config.
  API_SERVER=$(kubectl --context ${CENTRAL_CTX} get node -l node-role.kubernetes.io/control-plane -o json \
    | jq -r '.items[] | .status.addresses[] | select(.type=="InternalIP") | .address')
  if [[ "${ISTIO_ENABLED}" == "yes" ]]; then
    istioctl create-remote-secret \
      --context=${CENTRAL_CTX} \
      --server https://${API_SERVER}:6443 \
      --name=${CENTRAL} | \
      kubectl --context ${REMOTE_CTX} apply -f -
    if [[ "${ISTIO_PROFILE}" == "ambient" ]]; then
      for SVC in "${SERVICES[@]}"; do
        kubectl --context ${CENTRAL_CTX} get $SVC -o yaml | sed '/clusterIP:/,+6d' | \
          kubectl --context ${REMOTE_CTX} apply -f -
      done
    fi
  else
    # Generate Link CR and credentials using link-gen
    echo "Generating Link CR and credentials for cluster: ${CENTRAL}"
    linkerd --context ${CENTRAL_CTX} mc link-gen \
      --cluster-name ${CENTRAL} \
      --api-server-address="https://${API_SERVER}:6443" \
      > /tmp/link-${CENTRAL}.yaml

    echo "Applying Link CR to remote cluster (${REMOTE_CTX})"
    kubectl --context ${REMOTE_CTX} apply -f /tmp/link-${CENTRAL}.yaml

    echo "Configuring linkerd-multicluster to manage service-mirror controller"

    cat <<EOF > /tmp/multicluster-controllers.yaml
controllers:
- link:
    ref:
      name: ${CENTRAL}

controllersDefaults:
  logLevel: info
  logFormat: plain
EOF

    # Upgrade multicluster installation with controller config
    echo "Upgrading linkerd-multicluster with controller configuration"
    helm upgrade linkerd-multicluster linkerd-edge/linkerd-multicluster \
      --namespace linkerd-multicluster \
      --kube-context ${REMOTE_CTX} \
      -f /tmp/multicluster-controllers.yaml \
      --reuse-values \
      --wait

    echo "Waiting for service-mirror controller to be ready"
    kubectl --context ${REMOTE_CTX} -n linkerd-multicluster rollout status \
      deployment/controller-${CENTRAL} --timeout=5m || {
        echo "Warning: Controller deployment not ready yet, checking pods..."
        kubectl --context ${REMOTE_CTX} -n linkerd-multicluster get pods -l linkerd.io/control-plane-component=controller
      }

    echo "Multicluster linking complete!"
  fi
fi
