# Kubernetes Environment

**AgentForge** runs on a three-node Hyper-V cluster. The control plane hosts the
NFS server; both workers carry agent workloads.

```mermaid
graph TB
    subgraph HyperV["Hyper-V Host (Windows 11)"]
        subgraph K8sSwitch["K8sSwitch — 192.168.100.0/24"]
            subgraph CP["k8s-control  192.168.100.10  (4 GB RAM)"]
                etcd["etcd"]
                api["kube-apiserver"]
                nfs["NFS Server<br>/srv/nfs/k8s"]
                flannel_cp["flannel"]
            end

            subgraph W1["k8s-worker1  192.168.100.11  (4 GB RAM)"]
                registry["Registry<br>:30500 NodePort"]
                agent_pods_1["Agent Pods<br>(architect / coder)"]
                flannel_w1["flannel"]
            end

            subgraph W2["k8s-worker2  192.168.100.12  (4 GB RAM)"]
                dispatcher["Dispatcher Pod<br>+ queue-watcher"]
                agent_pods_2["Agent Pods<br>(tester / reviewer / ops)"]
                flannel_w2["flannel"]
            end
        end

        subgraph Addons["Cluster Add-ons"]
            metallb["MetalLB<br>192.168.100.200–220"]
            ingress["nginx-ingress<br>192.168.100.200"]
            lpp["local-path-provisioner"]
        end
    end

    subgraph Storage["Persistent Storage"]
        nfs_pvc["NFS PVC<br>agent-memory 10Gi RWX<br>/memory shared by all agents"]
        reg_pvc["local-path PVC<br>registry 20Gi RWO"]
    end

    nfs -->|"serves"| nfs_pvc
    nfs_pvc -->|"mounted by"| agent_pods_1
    nfs_pvc -->|"mounted by"| agent_pods_2
    nfs_pvc -->|"mounted by"| dispatcher
    registry --- reg_pvc
    metallb --> ingress
    ingress -->|"webhook.k8s.local"| dispatcher
```

## Node Roles

| Node | IP | Key Workloads |
|------|----|---------------|
| k8s-control | 192.168.100.10 | Control plane, NFS server |
| k8s-worker1 | 192.168.100.11 | Local registry (NodePort :30500), agent pods |
| k8s-worker2 | 192.168.100.12 | Dispatcher + queue-watcher, agent pods |

- **CNI:** Flannel `10.244.0.0/16`
- **Storage classes:** `nfs` (RWX for agent memory), `local-path` (RWO for registry)
- **Load balancer:** MetalLB pool `192.168.100.200–220`
- **Ingress:** nginx at `192.168.100.200` → `webhook.k8s.local`
