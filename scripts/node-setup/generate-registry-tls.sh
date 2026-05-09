#!/bin/bash
# =============================================================================
# generate-registry-tls.sh
# Generate a self-signed CA and server certificate for the local registry.
# Run from WSL when setting up the cluster for the first time, or if certs
# are lost.
#
# Output: /tmp/registry-tls/{ca.key, ca.crt, tls.key, tls.crt}
# WARNING: ca.key is sensitive — do NOT commit it to git.
#
# After running this script:
#   1. Create the K8s secret:
#      kubectl create secret tls registry-tls \
#        --cert=/tmp/registry-tls/tls.crt \
#        --key=/tmp/registry-tls/tls.key \
#        -n claude-agents
#   2. Deploy the CA to all nodes:
#      ./scripts/node-setup/deploy-node-setup.sh
#   3. Helm upgrade to deploy the TLS registry:
#      cd helm/claude-agents-v6 && helm upgrade claude-agents . -n claude-agents
#
# Node IPs covered by the cert SAN:
#   192.168.100.10 (k8s-control)
#   192.168.100.11 (k8s-worker1 — registry NodePort host)
#   192.168.100.12 (k8s-worker2)
# =============================================================================

set -euo pipefail

OUT=/tmp/registry-tls
mkdir -p "$OUT"

echo "Generating registry TLS certificates in $OUT..."

# CA key and cert (10 year validity)
openssl genrsa -out "$OUT/ca.key" 4096 2>/dev/null
openssl req -new -x509 -days 3650 -key "$OUT/ca.key" \
  -subj "/CN=lab-registry-ca" \
  -out "$OUT/ca.crt" 2>/dev/null

# Server key
openssl genrsa -out "$OUT/tls.key" 4096 2>/dev/null

# Server CSR with SANs
openssl req -new -key "$OUT/tls.key" \
  -subj "/CN=192.168.100.11" \
  -reqexts SAN \
  -config <(cat /etc/ssl/openssl.cnf <(printf '[SAN]\nsubjectAltName=IP:192.168.100.11,IP:192.168.100.10,IP:192.168.100.12,IP:127.0.0.1,DNS:localhost')) \
  -out "$OUT/tls.csr" 2>/dev/null

# Sign with CA (10 year validity)
openssl x509 -req -days 3650 -in "$OUT/tls.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -extensions SAN \
  -extfile <(printf '[SAN]\nsubjectAltName=IP:192.168.100.11,IP:192.168.100.10,IP:192.168.100.12,IP:127.0.0.1,DNS:localhost') \
  -out "$OUT/tls.crt" 2>/dev/null

echo ""
echo "Generated:"
ls -lh "$OUT/"
echo ""
echo "Verify cert chain:"
openssl verify -CAfile "$OUT/ca.crt" "$OUT/tls.crt" 2>/dev/null && echo "  OK"
echo ""
echo "SANs:"
openssl x509 -in "$OUT/tls.crt" -noout -text 2>/dev/null | grep -A1 "Subject Alternative"
echo ""
echo "Expires:"
openssl x509 -in "$OUT/tls.crt" -noout -dates 2>/dev/null
echo ""
echo "Next steps:"
echo "  kubectl create secret tls registry-tls --cert=$OUT/tls.crt --key=$OUT/tls.key -n claude-agents"
echo "  ./scripts/node-setup/deploy-node-setup.sh"
