# containerd 2.x CRI Image Service Ignores hosts.toml for Insecure Registries

**Date:** 2026-05-09

## Symptoms

Agent pods fail to pull images from the local registry (`192.168.100.11:30500`) with:
```
failed to pull and unpack image "192.168.100.11:30500/...":
failed to resolve image: failed to do request:
Head "https://192.168.100.11:30500/v2/.../manifests/...":
http: server gave HTTP response to HTTPS client
```
This occurs even when `hosts.toml` specifies `server = "http://..."` and `skip_verify = true`.
`ctr images pull --plain-http` works fine — the problem is specific to the CRI path.

## Root Cause

containerd 2.x split image pulling into two plugins:

1. `io.containerd.transfer.v1.local` — the transfer plugin, used by `ctr`
2. `io.containerd.cri.v1.images` — the CRI image service, used by kubelet/Kubernetes

The CRI image service has a regression in 2.2.1: it unconditionally attempts HTTPS for
the initial manifest HEAD request before consulting `hosts.toml`. Even with `config_path`
correctly set, the fields `skip_verify` and `ca` in `hosts.toml` are not honoured by the
CRI image service. Only the system CA trust store is respected.

**Additional gotcha:** Adding inline `[plugins.'io.containerd.cri.v1.images'.registry.mirrors....]`
entries to `config.toml` is **mutually exclusive** with `config_path`. containerd refuses
to load the CRI plugin with:
```
unable to load CRI image service plugin dependency: invalid cri image config:
`mirrors` cannot be set when `config_path` is provided
```
This takes all nodes NotReady.

## Fix

1. Make the registry serve HTTPS (self-signed cert is fine)
2. Install the CA cert in the system trust store on all nodes:
   ```bash
   sudo cp ca.crt /usr/local/share/ca-certificates/lab-registry-ca.crt
   sudo update-ca-certificates
   sudo systemctl restart containerd
   ```
3. Update `hosts.toml` to use `https://` and reference the CA:
   ```toml
   server = "https://192.168.100.11:30500"
   [host."https://192.168.100.11:30500"]
     capabilities = ["pull", "resolve", "push"]
     ca = ["/etc/containerd/certs.d/192.168.100.11:30500/ca.crt"]
   ```
   (The `ca` field in hosts.toml is not honoured by the CRI path but doesn't hurt;
   the system trust store is what actually makes it work.)

## Prevention

- Never configure a local registry as HTTP-only on a containerd 2.x cluster.
- When editing `config.toml` via script: never mix `config_path` and inline `mirrors`/`configs`.
- If nodes go NotReady after a containerd config change, check for this error:
  `sudo journalctl -u containerd -n 20 | grep "failed to load plugin"`
- To restore a broken `config.toml`: `sudo containerd config default > /etc/containerd/config.toml`
  then apply only the transfer plugin fix:
  ```python
  re.sub(r"(io\.containerd\.transfer\.v1\.local.*?)config_path = ''",
         r"\1config_path = '/etc/containerd/certs.d'", text, flags=re.DOTALL)
  ```
