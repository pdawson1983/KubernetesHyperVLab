# ADR: Local Registry TLS via Self-Signed CA in System Trust Store

**Date:** 2026-05-09
**Status:** accepted

## Context

The local container registry at `192.168.100.11:30500` was initially HTTP-only. When
containerd was at 1.7.x, `hosts.toml` with `skip_verify = true` allowed HTTP pulls via
the CRI image service. The cluster later ran containerd 2.2.1.

In containerd 2.x, the CRI image service (`io.containerd.cri.v1.images`) introduced a
regression: it ignores `hosts.toml` for the initial manifest resolution step and
unconditionally tries HTTPS. Attempts to work around this by:
- Using HTTP-only registry with `hosts.toml` → "http: server gave HTTP response to HTTPS client"
- Adding inline `mirrors` + `configs` to config.toml → incompatible with `config_path`,
  breaks the CRI plugin entirely (nodes go NotReady)
- Setting `skip_verify = true` in hosts.toml with HTTPS registry → not honoured by CRI path
- Setting `ca = [...]` in hosts.toml with HTTPS registry → also not honoured by CRI path

Only one approach worked: **adding the CA cert to the Ubuntu system trust store**.

Three approaches were weighed:

1. **System trust store (`update-ca-certificates`)** — one-time setup per node; containerd
   and kubelet both use the system CA bundle for TLS verification; no per-registry config.
2. **hosts.toml ca field** — containerd 2.2.1 CRI image service ignores it (confirmed
   by testing; `skip_verify` also ignored).
3. **Continue with Docker Hub** — eliminates local registry entirely; rate limits not a
   practical concern for lab usage but eliminates local-network pull speed advantage.

## Decision

Use HTTPS on the registry with a self-signed CA, and install the CA cert into the system
trust store on all nodes.

- Self-signed CA and server cert generated with 10-year validity
- Server cert SANs: all three node IPs (192.168.100.10/11/12), 127.0.0.1, localhost
- Registry deployment: `REGISTRY_HTTP_TLS_CERTIFICATE` and `REGISTRY_HTTP_TLS_KEY` env
  vars point to a mounted TLS secret (`registry-tls`)
- Probes changed from `httpGet` to `tcpSocket` (endpoint is now HTTPS)
- All nodes: `sudo cp ca.crt /usr/local/share/ca-certificates/lab-registry-ca.crt &&
  sudo update-ca-certificates && sudo systemctl restart containerd`
- Push from WSL uses `podman push --tls-verify=false` (self-signed cert not in WSL trust)
- `values.yaml` `global.image.repository` switched from `docker.io/pdawson1983/claude-agent`
  to `192.168.100.11:30500/claude-agent`

## Consequences

- **Easier:** Image pulls are now on the local 1Gbps network instead of internet;
  Docker Hub rate limits no longer apply; no dependency on Docker Hub availability.
- **Harder:** TLS key material (`/tmp/registry-tls/` on WSL) must be preserved or
  regenerated if lost; nodes must have CA reinstalled if re-imaged; push from WSL
  requires `--tls-verify=false`.
- **Watch for:** The 10-year CA expires 2036-05-06. The `registry-tls` K8s secret holds
  the server cert — if the cluster is rebuilt, the secret must be recreated from the
  saved CA. The CA key is NOT committed to git.
