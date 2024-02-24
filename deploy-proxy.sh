#!/bin/bash

INGRESS_IP=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

cat <<EOF > haproxy.cfg
global
  stats socket /var/run/api.sock user haproxy group haproxy mode 660 level admin expose-fd listeners
  log stdout format raw local0 info

defaults
  mode tcp
  timeout client 10s
  timeout connect 5s
  timeout server 10s
  timeout http-request 10s
  log global

frontend stats
  mode http
  bind *:8404
  stats enable
  stats uri /
  stats refresh 10s

frontend http_external
  bind *:80
  default_backend http_workers

frontend https_external
  bind *:443
  default_backend https_workers

backend http_workers
  server ingress ${INGRESS_IP}:80 check

backend https_workers
  server ingress ${INGRESS_IP}:443 check
EOF

sudo docker run -d --name haproxy --net kind \
   -v $(pwd)/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
   -p 80:80 -p 443:443 -p 8404:8404 \
   haproxytech/haproxy-alpine

