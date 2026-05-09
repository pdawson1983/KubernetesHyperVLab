#!/bin/bash
# =============================================================================
# configure-containerd.sh
# Run on each cluster node (with sudo) after a rebuild or fresh node setup.
#
# What it does:
#   1. Regenerates /etc/containerd/config.toml from defaults
#   2. Sets config_path on the transfer plugin (io.containerd.transfer.v1.local)
#      so containerd 2.x reads /etc/containerd/certs.d/ for registry config
#   3. Installs nfs-common (required for NFS PVC mounts)
#   4. Restarts containerd
#
# Why:
#   containerd 2.x split image pulling into a transfer plugin that does NOT
#   inherit the CRI image plugin's config_path by default. Without this fix,
#   the transfer plugin ignores hosts.toml and the registry CA cert.
#   See: K8s HyperV Lab Documents/knowledge/containerd2-cri-insecure-registry.md
#
# Usage:
#   ssh -t pdawson@<node-ip> "sudo bash /tmp/configure-containerd.sh"
# =============================================================================

set -e

echo "Configuring containerd on $(hostname)..."

# Install nfs-common if missing (needed for NFS PVC mounts)
if ! dpkg -l nfs-common 2>/dev/null | grep -q '^ii'; then
  echo "Installing nfs-common..."
  apt-get install -y nfs-common
fi

# Regenerate config from defaults and apply transfer plugin fix
containerd config default > /tmp/containerd-fresh.toml

python3 - /tmp/containerd-fresh.toml << 'PYEOF'
import sys, re

path = sys.argv[1]
text = open(path).read()

text = re.sub(
    r"(\[plugins\.'io\.containerd\.transfer\.v1\.local'\][^\[]*?)config_path = ''",
    r"\1config_path = '/etc/containerd/certs.d'",
    text,
    flags=re.DOTALL
)

open(path, 'w').write(text)
print("Transfer plugin config_path set")
PYEOF

cp /tmp/containerd-fresh.toml /etc/containerd/config.toml
systemctl restart containerd
sleep 2

# Verify CRI plugin loaded correctly
if journalctl -u containerd -n 5 --no-pager 2>/dev/null | grep -q "failed to load plugin"; then
  echo "ERROR: containerd CRI plugin failed to load — check config.toml"
  journalctl -u containerd -n 10 --no-pager | grep "failed to load"
  exit 1
fi

echo "Done on $(hostname) — containerd: $(systemctl is-active containerd)"
