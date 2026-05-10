# Tasks

Open work items for the K8s HyperV Lab. Update status and add outcome notes when resolved.

---

## In Progress

| Task | Notes |
|------|-------|

---

## Backlog

| Task                                               | Priority | Notes                                                                                                                                                                                                                                                                                               |
| -------------------------------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Observability data layer (Postgres)                | High     | Postgres in-cluster stores per-run structured data: turns used, tools called, token counts, agent decisions, outcomes. Same DB used by web UI and self-improvement loop. Replaces JSON telemetry files. Loki+Grafana considered but deferred — Postgres covers both observability and web UI needs. |
| System self-improvement loop                       | High     | `system.improve` event routes to architect with this repo as target; architect reads observability DB to identify inefficiencies in agent-base.md / CLAUDE.md files; ops opens a PR with proposed changes. Requires observability data layer first. Add to TRIGGER_MAP.                             |
| Build web UI + Postgres                            | Medium   | Task submission UI (MD upload + guided form); Postgres backend shared with observability layer. Build together — same DB deployment covers both.                                                                                                                                                    |
| Validate WSL route persistence scheduled task      | Medium   | Route `192.168.100.0/24 via 172.24.240.1` drops on WSL restart; task exists but unverified                                                                                                                                                                                                          |
| Add human approval gate between Reviewer and Ops   | Low      | Queue-watcher currently auto-chains; needs a pause point                                                                                                                                                                                                                                            |
| Add GitHub webhook integration                     | Low      | Real repo events → pipeline trigger                                                                                                                                                                                                                                                                 |
| Add Tekton for more complex pipeline orchestration | Low      | Current CronJob-as-template pattern has limits at scale                                                                                                                                                                                                                                             |

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
| Add securityContext to dispatcher pod (runAsUser: 1001) | 2026-05-09 | Done in commit 9fa1b57 — pod-level securityContext runAsUser/runAsGroup/fsGroup all 1001 |
| Credential auto-refresh script | 2026-05-10 | scripts/refresh-credentials.sh — checks expiresAt, runs claude auth login only if within 2h threshold, recreates K8s secret |
| Agent CronJob securityContext (runAsUser: 1001) | 2026-05-10 | Pod-level runAsUser/runAsGroup/fsGroup/runAsNonRoot added to all 5 agents via claude-agents.agentSecurityContext helper; mock 14/14 |
| Git repo integration | 2026-05-10 | repoUrl flows through payload; GITHUB_TOKEN injected into agents; git URL rewrite in entrypoint.sh; branch naming agentforge/<task-id>; agent-base.md repo section; mock 14/14 |
| First real end-to-end run (pdawson1983/testrepo) | 2026-05-10 | architect→coder→tester→reviewer→ops all succeeded; hello.py committed to branch agentforge/20260510-130541-c173; PR #1 opened; 361s total |
| Per-agent maxTurns | 2026-05-10 | architect:20 coder:50 tester:40 reviewer:25 ops:30; global.maxTurns=0 uses per-agent values; fixes tester hitting 10-turn limit |
| Persistent entrypoint logging | 2026-05-10 | log() tees to NFS logs/<role>-entrypoint.log; exit_code in task.json; last 30 lines of Claude output on failure; image 20260510-131545 |
| Rotate GitHub PAT | 2026-05-10 | Done — token rotated by user |
| MCP extensibility pattern — GitHub MCP server | 2026-05-10 | github-mcp-server v1.0.3 running in-cluster (HTTP :8080); entrypoint.sh wires mcpServers from queue file into ~/.claude/settings.json; mock 14/14 |
| System diagrams (Mermaid) | 2026-05-10 | Four diagrams added to K8s HyperV Lab Documents/diagrams/: cluster topology, agent flow, MCP pattern, WSL connectivity |
| System named AgentForge | 2026-05-10 | Name adopted for docs and diagrams; Helm release remains claude-agents internally |
| Permission allowlist (.claude/settings.json) | 2026-05-10 | 13 read-only patterns added: kubectl get/logs/describe, helm template/list, aws apprunner/s3/secretsmanager/iam/logs read commands |
