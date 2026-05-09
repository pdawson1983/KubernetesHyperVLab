#!/bin/bash
# =============================================================================
# install-registry-ca.sh
# Run on each cluster node (with sudo) after a rebuild or fresh node setup.
#
# What it does:
#   1. Installs the registry CA cert to the system trust store so containerd
#      2.x CRI image service trusts the local registry (192.168.100.11:30500)
#   2. Configures /etc/containerd/certs.d/192.168.100.11:30500/hosts.toml
#      to use HTTPS with the CA cert
#   3. Restarts containerd
#
# Usage:
#   # From WSL — copy CA cert to node first, then run:
#   scp /tmp/registry-tls/ca.crt pdawson@<node-ip>:/tmp/registry-ca.crt
#   ssh -t pdawson@<node-ip> "sudo bash /tmp/install-registry-ca.sh"
#
#   # Or from the repo, run deploy-node-setup.sh which does all nodes at once
# =============================================================================

set -e

CA_SRC="${1:-/tmp/registry-ca.crt}"
REGISTRY="192.168.100.11:30500"
CERT_DIR="/etc/containerd/certs.d/${REGISTRY}"

if [ ! -f "$CA_SRC" ]; then
  echo "ERROR: CA cert not found at $CA_SRC"
  echo "Copy it first: scp /tmp/registry-tls/ca.crt pdawson@\$(hostname -I | awk '{print \$1}'):/tmp/registry-ca.crt"
  exit 1
fi

echo "Installing registry CA cert on $(hostname)..."

# System trust store
cp "$CA_SRC" /usr/local/share/ca-certificates/lab-registry-ca.crt
update-ca-certificates

# containerd hosts.toml
mkdir -p "$CERT_DIR"
cp "$CA_SRC" "$CERT_DIR/ca.crt"
cat > "$CERT_DIR/hosts.toml" << TOML
server = "https://${REGISTRY}"

[host."https://${REGISTRY}"]
  capabilities = ["pull", "resolve", "push"]
  ca = ["${CERT_DIR}/ca.crt"]
TOML

systemctl restart containerd
sleep 2
echo "Done on $(hostname) — containerd: $(systemctl is-active containerd)"
