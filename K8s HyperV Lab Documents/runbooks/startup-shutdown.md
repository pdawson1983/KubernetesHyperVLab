# Runbook: Starting and Stopping the Cluster

## Pause vs. Shutdown

**Pause (Hyper-V checkpoint / saved state)** — preferred for short stops.
The VMs freeze in memory. On resume, the OS clocks will be skewed but
Kubernetes usually recovers within ~60 seconds as kubelet re-syncs.
The WSL route survives if WSL itself wasn't restarted.

**Shutdown (full power off)** — use for long stops or before host reboots.
Requires the startup sequence below. NFS mounts may need a moment to re-establish.

---

## Startup Sequence (after shutdown or host reboot)

Order matters — k8s-control must be ready before workers try to mount NFS.

1. **Start k8s-control first** (192.168.100.10)
   - Hosts the NFS server (`/srv/nfs/k8s`) and the Kubernetes API server
   - Wait ~30s for it to fully boot before starting workers

2. **Start k8s-worker1 and k8s-worker2** (can start simultaneously)

3. **Verify nodes are Ready**
   ```bash
   kubectl get nodes
   ```
   All three should show `Ready` within ~60–90s.

4. **Check the WSL route** (drops on WSL or Windows restart)
   ```bash
   ip route show | grep 192.168.100
   ```
   If missing, re-add:
   ```bash
   sudo ip route add 192.168.100.0/24 via 172.24.240.1
   ```
   > The gateway `172.24.240.1` may change after WSL restarts. If the route
   > command fails, find the current gateway with:
   > `ip route show | grep default`

5. **Verify dispatcher is running**
   ```bash
   kubectl get pods -n claude-agents
   curl -s http://webhook.k8s.local/healthz
   ```

---

## Shutdown Sequence

Graceful order (optional but cleaner):

1. Scale dispatcher to 0 to prevent in-flight jobs:
   ```bash
   kubectl scale deployment claude-agents-claude-agents-webhook -n claude-agents --replicas=0
   ```
2. Wait for any running agent pods to finish (or delete them):
   ```bash
   kubectl get pods -n claude-agents
   ```
3. Shutdown workers first, then k8s-control.

For a quick stop (pause or emergency), just pause/shutdown in any order —
Kubernetes will recover on resume/restart.

---

## After Resume from Pause

Usually no action needed. Check:

```bash
kubectl get nodes          # all Ready?
kubectl get pods -n claude-agents   # dispatcher running?
```

If nodes show `NotReady` for more than 2 minutes after resume, the kubelet
clock skew may be too large. On each affected node:
```bash
sudo systemctl restart kubelet
```

---

## WSL Route Persistence

The scheduled task `WSL-K8s-Route` (see `k8s-hyperv-guide.md`) should
re-add the route automatically on Windows login. If it's not running:

```powershell
# In Windows PowerShell as Administrator
Start-ScheduledTask -TaskName "WSL-K8s-Route"
Get-ScheduledTaskInfo -TaskName "WSL-K8s-Route"
```

**Status:** This task exists but has not been confirmed working after a real
reboot. Validate and mark confirmed when tested.
