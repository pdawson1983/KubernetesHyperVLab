# WSL ↔ Kubernetes Connectivity

How the WSL2 development environment connects to the Hyper-V cluster for image
pushes, kubectl commands, and webhook testing.

```mermaid
graph TB
    subgraph Windows["Windows 11 Host"]
        subgraph WSL2["WSL2 (Ubuntu 22.04)"]
            Dev["Developer<br>kubectl / helm / podman / curl"]
            Route["Static Route<br>192.168.100.0/24<br>via 172.24.240.1"]
            Hosts["/etc/hosts<br>192.168.100.200 webhook.k8s.local"]
        end

        subgraph HyperV["Hyper-V"]
            NAT["NAT Gateway<br>172.24.240.1"]
            subgraph K8sSwitch["K8sSwitch  192.168.100.0/24"]
                CP["k8s-control<br>.10"]
                W1["k8s-worker1<br>.11<br>Registry :30500"]
                LB["MetalLB LB IP<br>.200<br>(nginx-ingress)"]
            end
        end
    end

    Dev -->|"kubectl / helm<br>via kubeconfig"| CP
    Dev -->|"podman push :30500<br>--tls-verify=false<br>(self-signed CA)"| W1
    Dev -->|"curl webhook.k8s.local<br>HMAC-signed POST"| Hosts
    Hosts -->|"resolves to .200"| LB
    Route -->|"routes cluster CIDR<br>through Hyper-V NAT"| NAT
    NAT --> K8sSwitch
```

## Route Persistence

The static route drops on WSL restart and must be re-added:

```bash
sudo ip route add 192.168.100.0/24 via 172.24.240.1
```

A Windows scheduled task exists to restore this automatically but has not been
fully validated (see tasks.md backlog).

## Registry TLS

The local registry at `192.168.100.11:30500` serves HTTPS with a self-signed cert.

- **Push from WSL:** `podman push ... --tls-verify=false` (bypasses cert check on push)
- **Pull from nodes:** nodes trust the CA via system trust store
  (`/usr/local/share/ca-certificates/lab-registry-ca.crt`)
- **TLS key material:** `/tmp/registry-tls/` on WSL — not committed; regenerate if lost

## Hosts File (WSL + Windows)

Both WSL `/etc/hosts` and Windows `C:\Windows\System32\drivers\etc\hosts` need:

```
192.168.100.200 webhook.k8s.local
```

This maps the MetalLB IP to the ingress hostname used by the webhook dispatcher.
