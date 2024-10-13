#!/bin/bash

set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

for cmd in "istioctl" "kubectl"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

CONTEXT=${CONTEXT-}
CERT_ISSUER_ID=${CERT_ISSUER_ID-}

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
  --from-file=cert-chain.pem=istio-${CERT_ISSUER_ID}-chain.crt

# https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/
# https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
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
        holdApplicationUntilProxyStarts: true
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
    defaultConfig:
      holdApplicationUntilProxyStarts: true
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
  components:
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
