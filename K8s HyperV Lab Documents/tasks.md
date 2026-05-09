# Tasks

Open work items for the K8s HyperV Lab. Update status and add outcome notes when resolved.

---

## In Progress

| Task | Notes |
|------|-------|

---

## Backlog

| Task | Priority | Notes |
|------|----------|-------|
| Credential auto-refresh | High | Claude.ai OAuth tokens expire ~every 24h; need script to detect expiry and recreate K8s secret automatically |
| Add securityContext (runAsUser: 1001) to dispatcher pod | High | Queue-watcher writes trigger files as root; agents (UID 1001) can't delete them. Fix: add fsGroup/runAsUser to dispatcher securityContext |
| Add securityContext (runAsUser: 1001) to agent CronJob templates | Medium | agent user UID 1001 is set in Dockerfile but not enforced at K8s level |
| System self-improvement loop | Medium | `system.improve` event type routes to architect with this repo as target; ops opens a PR. Add to TRIGGER_MAP. |
| Git repo integration | Medium | Accept repo URL in task payload; coder clones into /memory/tasks/<id>/workspace/<repo>/ and pushes branch |
| Public repo push / GitHub PR | Medium | Ops agent opens a GitHub PR; requires git credentials secret + GitHub token |
| Post-run telemetry | Medium | Ops appends structured log (timing, success/fail) to /memory/telemetry/; meta-agent proposes tuning |
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
| Downgrade containerd 2.2.1 → 1.7.24 | — | Fixed insecure registry hosts.toml bug (note: later reverted — see ADR-010) |
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
| Fix Docker Hub :latest serving stale image to nodes | 2026-05-08 | Switched to versioned tags (YYYYMMDD-HHMMSS) + IfNotPresent pullPolicy; values.yaml pinned to tag |
| Switch cluster auth to Claude Max credentials | 2026-05-08 | Disabled API key; created claude-credentials secret from ~/.claude/.credentials.json; enabled in values.yaml |
| Fix credentials defaultMode 0400 → 0444 | 2026-05-08 | Agent UID 1001 couldn't read secret mounted with owner-only mode; changed in _helpers.tpl |
| Fix pipeline-test.sh pod detection (multiple iterations) | 2026-05-08 | Replaced timestamp filter with pre-existing pod snapshot + python3 tempfile filter; jq not installed in WSL |
| pipeline-test.sh --mock passing 12/12 | 2026-05-08 | Full 5-agent chain validated at zero token cost in ~28 seconds |
| pipeline-test.sh --haiku passing 6/7 | 2026-05-08 | Architect→coder→tester→reviewer chain confirmed with real Claude Max credentials; tester timeout pending |
| Task-scoped memory namespacing | 2026-05-09 | /memory/tasks/<task-id>/ per run; TASK_ID injected via dry-run+apply; dispatcher chmods 0o777; mock 14/14 |
| Task metadata registry | 2026-05-09 | Dispatcher writes task.json on creation (task_id, event, title, created_at, status) |
| Task ID in webhook response | 2026-05-09 | Confirmed present as `task_id` field in HTTP 200 JSON response body |
| Fix haiku test tester timeout | 2026-05-09 | Bumped agents.tester.timeout from 300s to 600s in values.yaml |
| Local registry TLS (containerd 2.x) | 2026-05-09 | Self-signed CA, system trust store on all nodes, registry serves HTTPS; agents pull from 192.168.100.11:30500 |
| Validate local registry after containerd fix | 2026-05-09 | Working after TLS setup + CA in system trust store; switched image repo in values.yaml |
| Expand control plane LVM volume | 2026-05-09 | No action needed — LV already 17.3GB using full 20GB disk (no gap, unlike workers) |
