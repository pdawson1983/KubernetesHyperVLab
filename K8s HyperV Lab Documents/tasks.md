# Tasks

Open work items for the K8s HyperV Lab. Update status and add outcome notes when resolved.

---

## In Progress

| Task | Notes |
|------|-------|
| Fix haiku test tester timeout | Tester hits AGENT_TIMEOUT=300s when using Haiku; needs per-agent timeout tuning or simpler test task |

---

## Backlog

| Task | Priority | Notes |
|------|----------|-------|
| Task-scoped memory namespacing | High | /memory/tasks/<task-id>/ per run; enables concurrent tasks and multi-repo support. Next session. |
| Expand control plane LVM volume | High | Same 10GB gap as workers; expand before it causes issues |
| Add securityContext (runAsUser: 1001) to dispatcher pod | High | Queue-watcher writes trigger files as root; agents (UID 1001) can't delete them. Fix: add fsGroup/runAsUser to dispatcher securityContext |
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
| Fix trigger file race condition | 2026-05-07 | Queue-watcher moves trigger to queue/active/ before dispatching; entrypoint.sh reads from there as fallback |
| Expand worker LVM volumes (10GB → 17GB) | 2026-05-07 | Both workers expanded online with lvextend + resize2fs |
| Verify full pipeline run: Architect → Coder → Tester → Reviewer → Ops | 2026-05-07 | All 5 agents completed; deployment.yaml produced by Ops for hello-world-endpoint |
| Validate tester → reviewer → ops chain | 2026-05-07 | Confirmed: full chain ran; reviews and deployment artifacts written to /memory/ |
| Add Claude.ai Max credentials support | 2026-05-07 | Credentials secret mounted at /home/agent/.claude-creds; entrypoint copies to ~/.claude/ at startup |
| Decouple agent behaviour from Helm (ADR-006) | 2026-05-07 | Per-role ConfigMap instructions removed; general instructions baked into image as /agent/CLAUDE.md |
| Create pipeline smoke test script | 2026-05-07 | scripts/pipeline-test.sh with --mock (zero tokens) and --haiku (minimal tokens) modes |
| Create /session-doc skill | 2026-05-07 | Installed at ~/.claude/commands/session-doc.md; updates all lab docs at end of session |
| Fix pod false-Error on NFS trigger file cleanup | 2026-05-08 | rm -f on queue/active/ files failed with Permission denied (UID mismatch); made cleanup non-fatal in entrypoint.sh |
| Fix Docker Hub :latest serving stale image to nodes | 2026-05-08 | Switched to versioned tags (YYYYMMDD-HHMMSS) + IfNotPresent pullPolicy; values.yaml pinned to 20260508-023415 |
| Switch cluster auth to Claude Max credentials | 2026-05-08 | Disabled API key; created claude-credentials secret from ~/.claude/.credentials.json; enabled in values.yaml |
| Fix credentials defaultMode 0400 → 0444 | 2026-05-08 | Agent UID 1001 couldn't read secret mounted with owner-only mode; changed in _helpers.tpl |
| Fix pipeline-test.sh pod detection (multiple iterations) | 2026-05-08 | Replaced timestamp filter with pre-existing pod snapshot + python3 tempfile filter; jq not installed in WSL |
| pipeline-test.sh --mock passing 12/12 | 2026-05-08 | Full 5-agent chain validated at zero token cost in ~28 seconds |
| pipeline-test.sh --haiku passing 6/7 | 2026-05-08 | Architect→coder→tester→reviewer chain confirmed with real Claude Max credentials; tester timeout pending |
