# Tasks

Open work items for the K8s HyperV Lab. Update status and add outcome notes when resolved.

---

## In Progress

| Task | Notes |
|------|-------|
| Verify full pipeline run: Architect → Coder → Tester → Reviewer → Ops | Architect → Coder chain confirmed (2026-05-07); coder running, tester/reviewer/ops not yet validated |

---

## Backlog

| Task | Priority | Notes |
|------|----------|-------|
| Validate tester → reviewer → ops chain | High | Coder now running; watch for tester.json to appear and chain to continue |
| Validate local registry after containerd downgrade to 1.7.24 | High | `curl http://192.168.100.11:30500/v2/_catalog` — if it works, switch image source from Docker Hub |
| Add securityContext (runAsUser: 1001) to agent CronJob templates | Medium | agent user UID 1001 is set in Dockerfile but not enforced at K8s level |
| Validate WSL route persistence scheduled task | Medium | Route `192.168.100.0/24 via 172.24.240.1` drops on WSL restart; task exists but unverified |
| Build web UI for task submission | Low | MD upload + guided form → POST to webhook.k8s.local |
| Add human approval gate between Reviewer and Ops | Low | Queue-watcher currently auto-chains; needs a pause point |
| Add GitHub webhook integration | Low | Real repo events → pipeline trigger |
| Add Tekton for more complex pipeline orchestration | Low | Current CronJob-as-template pattern has limits at scale |

---

## Completed

| Task | Completed | Outcome |
|------|-----------|---------|
| Hyper-V cluster (3 nodes) | — | All nodes Ready |
| Flannel CNI | — | `10.244.0.0/16` |
| MetalLB load balancer | — | Pool `192.168.100.200–220` |
| nginx-ingress | — | LB IP `192.168.100.200` |
| NFS storage (RWX for agent memory) | — | `/srv/nfs/k8s` on k8s-control |
| local-path storage (registry PVC) | — | Rancher local-path-provisioner |
| Helm chart deploying cleanly | — | v0.5.0, release `claude-agents` |
| Webhook dispatcher running + HMAC validation | — | Receiving events at webhook.k8s.local |
| Dispatcher writing payloads to /memory/inbox/ | — | Confirmed |
| CronJob templates spawning agent Jobs | — | `kubectl create job --from cronjob/` |
| Docker Hub image pulling correctly | — | `docker.io/pdawson1983/claude-agent:latest` |
| Architect agent running end to end | — | Claude Code called, spec written, coder.json triggered |
| Downgrade containerd 2.2.1 → 1.7.24 | — | Fixed insecure registry hosts.toml bug |
| Queue-watcher sidecar chaining pipeline | 2026-05-07 | Confirmed: architect.complete → coder job spawned and running |
| Fix trigger file race condition (queue-watcher archives before agent starts) | 2026-05-07 | Queue-watcher now moves trigger to queue/active/ before dispatching; entrypoint.sh reads from there as fallback |
| Expand worker LVM volumes (10GB → 17GB) | 2026-05-07 | Both workers were provisioned with 20GB disks but 10GB LV; expanded online with lvextend + resize2fs |
