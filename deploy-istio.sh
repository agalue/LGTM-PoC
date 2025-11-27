#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "istioctl" "kubectl"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CONTEXT=${CONTEXT-}
CERT_ISSUER_ID=${CERT_ISSUER_ID-}
SERVICE_MESH_HA=${SERVICE_MESH_HA-no}
SERVICE_MESH_TRACES_ENABLED=${SERVICE_MESH_TRACES_ENABLED-no}
ISTIO_PROFILE=${ISTIO_PROFILE-default} # default or ambient

PILOT_REPLICAS="1"
if [[ "${SERVICE_MESH_HA}" == "yes" ]]; then
  PILOT_REPLICAS="3"
fi
TRACES_ENABLED="false"
if [[ "${SERVICE_MESH_TRACES_ENABLED}" == "yes" ]]; then
  TRACES_ENABLED="true"
fi

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
  labels:
    topology.istio.io/network: ${CONTEXT}
EOF

# https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/
kubectl create secret generic cacerts -n istio-system \
  --from-file=root-cert.pem=istio-root-ca.crt \
  --from-file=ca-cert.pem=istio-${CERT_ISSUER_ID}.crt \
  --from-file=ca-key.pem=istio-${CERT_ISSUER_ID}.key \
  --from-file=cert-chain.pem=istio-${CERT_ISSUER_ID}-chain.crt \
  --dry-run=client -o yaml | kubectl apply -f -

# https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/
# https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
# Removing resource requests and limits for demo purposes
if [[ "${ISTIO_PROFILE}" == "ambient" ]]; then
  # https://istio.io/latest/docs/ambient/install/multicluster/
  cat <<EOF | istioctl install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: ambient
  meshConfig:
    accessLogFile: /dev/stdout
    enableTracing: ${TRACES_ENABLED}
    extensionProviders:
    - name: otel-tracing
      opentelemetry:
        port: 4317
        service: grafana-alloy.observability.svc.cluster.local
        resource_detectors:
          environment: {}
  components:
    cni:
      k8s:
        resources:
          limits:
            cpu: '0'
            memory: '0'
          requests:
            cpu: '0'
            memory: '0'
    ztunnel:
      k8s:
        resources:
          limits:
            cpu: '0'
            memory: '0'
          requests:
            cpu: '0'
            memory: '0'
    pilot:
      k8s:
        replicaCount: ${PILOT_REPLICAS}
        affinity:
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: istiod
              topologyKey: kubernetes.io/hostname
        env:
        - name: AMBIENT_ENABLE_MULTI_NETWORK
          value: "true"
        resources:
          limits:
            cpu: '0'
            memory: '0'
          requests:
            cpu: '0'
            memory: '0'
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: ${CONTEXT}
      network: ${CONTEXT}
EOF

  cat <<EOF | kubectl apply -f -
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: istio-eastwestgateway
  namespace: istio-system
  labels:
    topology.istio.io/network: ${CONTEXT}
spec:
  gatewayClassName: istio-east-west
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
    allowedRoutes:
      namespaces:
        from: All
    tls:
      mode: Terminate # represents double-HBONE
      options:
        gateway.istio.io/tls-terminate-mode: ISTIO_MUTUAL
EOF
else
  # https://github.com/istio/istio/blob/master/samples/multicluster/gen-eastwest-gateway.sh
  # https://istio.io/latest/docs/ops/configuration/traffic-management/dns-proxy/#sidecar-mode
  cat <<EOF | istioctl install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: ${CONTEXT}
      network: ${CONTEXT}
      proxy:
        resources:
          limits:
            cpu: '0'
            memory: '0'
          requests:
            cpu: '0'
            memory: '0'
      proxy_init:
        resources:
          limits:
            cpu: '0'
            memory: '0'
          requests:
            cpu: '0'
            memory: '0'
  meshConfig:
    accessLogFile: /dev/stdout
    defaultConfig:
      holdApplicationUntilProxyStarts: true
      proxyMetadata:
        # Enable basic DNS proxying
        ISTIO_META_DNS_CAPTURE: "true"
    enableTracing: ${TRACES_ENABLED}
    extensionProviders:
    - name: otel-tracing
      opentelemetry:
        port: 4317
        service: grafana-alloy.observability.svc.cluster.local
        resource_detectors:
          environment: {}
  components:
    pilot:
      k8s:
        replicaCount: ${PILOT_REPLICAS}
        affinity:
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: istiod
              topologyKey: kubernetes.io/hostname
        resources:
          limits:
            cpu: '0'
            memory: '0'
          requests:
            cpu: '0'
            memory: '0'
    ingressGateways:
    - name: lgtm-gateway
      label:
        istio: lgtm-gateway
        app: lgtm-gateway
        topology.istio.io/network: ${CONTEXT}
      enabled: true
      k8s:
        env:
        # traffic through this gateway should be routed inside the network
        - name: ISTIO_META_REQUESTED_NETWORK_VIEW
          value: ${CONTEXT}
        resources:
          limits:
            cpu: '0'
            memory: '0'
          requests:
            cpu: '0'
            memory: '0'
        service:
          ports:
          - name: status-port
            port: 15021
            targetPort: 15021
          - name: tls
            port: 15443
            targetPort: 15443
          - name: tls-istiod
            port: 15012
            targetPort: 15012
          - name: tls-webhook
            port: 15017
            targetPort: 15017
EOF

  # Multi-Cluster communication
  cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: cross-network-gateway
  namespace: istio-system
spec:
  selector:
    # Must match label from Ingress Gateway
    istio: lgtm-gateway
  servers:
  - port:
      number: 15443
      name: tls
      protocol: TLS
    tls:
      mode: AUTO_PASSTHROUGH
    hosts:
    - "*.local"
EOF
fi

# Istio Monitoring
curl https://raw.githubusercontent.com/istio/istio/refs/heads/master/samples/addons/extras/prometheus-operator.yaml 2>/dev/null \
  | sed '/release/s/istio/monitor/' | kubectl apply -f -
