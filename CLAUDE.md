# Claude Agents Pipeline — Project Status

## What This Is

A Kubernetes-native multi-agent pipeline running on a local Hyper-V cluster.
Five Claude Code agents (Architect, Coder, Reviewer, Tester, Ops) are
orchestrated via webhooks, share a persistent NFS memory volume, and chain
automatically through a queue-watcher sidecar.

---

## Infrastructure

### Hyper-V Cluster (Ubuntu 22.04 LTS)

| Node | IP | Role | RAM |
|------|----|------|-----|
| k8s-control | 192.168.100.10 | Control plane | 4GB |
| k8s-worker1 | 192.168.100.11 | Worker | 4GB |
| k8s-worker2 | 192.168.100.12 | Worker | 4GB |

- **Network:** Internal Hyper-V switch `K8sSwitch` (192.168.100.0/24) with NAT
- **CNI:** Flannel (`10.244.0.0/16`)
- **Load balancer:** MetalLB (pool: 192.168.100.200-220)
- **Ingress:** nginx-ingress-controller (192.168.100.200)
- **Storage:**
  - `local-path` storageclass (Rancher local-path-provisioner)
  - `nfs` storageclass (NFS server on k8s-control at `/srv/nfs/k8s`)
- **Container runtime:** containerd 2.2.1 (transfer plugin + CRI images plugin config_path both set to /etc/containerd/certs.d)
- **Kubernetes:** v1.29.15

### WSL Environment

- Ubuntu 22.04 in WSL2 on Windows 11
- Podman for container builds
- kubectl, helm configured
- Route: `192.168.100.0/24 via 172.24.240.1`
- `/etc/hosts`: `192.168.100.200 webhook.k8s.local`

---

## Repository Structure

```
KubernetesHyperVLab/
├── helm/
│   ├── claude-agents-v6/       ← ACTIVE chart (v0.5.0)
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── README.md
│   │   └── templates/
│   │       ├── _helpers.tpl
│   │       ├── namespace.yaml
│   │       ├── project-context.yaml
│   │       ├── NOTES.txt
│   │       ├── agents/
│   │       │   ├── configmaps.yaml   ← comment-only (instructions removed, see ADR-006)
│   │       │   └── jobs.yaml         ← suspended CronJobs (templates)
│   │       ├── ingress/
│   │       │   └── ingress.yaml      ← webhook only, registry excluded
│   │       ├── rbac/
│   │       │   └── rbac.yaml
│   │       ├── registry/
│   │       │   └── registry.yaml     ← NodePort :30500, local-path PVC
│   │       ├── storage/
│   │       │   └── pvc.yaml          ← NFS PVC, ReadWriteMany
│   │       ├── mcp/
│   │       │   └── github-mcp-server.yaml ← GitHub MCP server Deployment + ClusterIP Service
│   │       └── webhook/
│   │           └── dispatcher.yaml   ← dispatcher + queue-watcher sidecar
│   └── archive/                      ← v1-v5 kept for reference
│
├── scripts/
│   └── pipeline-test.sh            ← smoke test: --mock (zero tokens) or --haiku (minimal tokens)
│
└── claude-agent/
    └── claude-agent-image/
        ├── Dockerfile              ← node:20-slim + claude-code CLI
        ├── entrypoint.sh           ← finds payload, runs claude (or mock), exits
        ├── agent-base.md           ← baked into image as /agent/CLAUDE.md (general instructions)
        ├── queue-watcher.sh        ← watches /memory/queue/ (reference only)
        ├── test-local.sh           ← local test script
        └── README.md
```

---

## Helm Chart State

**Release:** `claude-agents` in namespace `agentforge`
**Chart version:** 0.8.0
**Revision:** 18
**Agent image:** `20260511-112123` | **Web UI image:** `20260511-113005`
**Image registry:** `192.168.100.11:30500` (local, HTTPS, self-signed CA trusted on all nodes)
**Auth:** Claude Max credentials (`claude-credentials` secret, `claudeCredentials.enabled: true`)

### What's Running

```
deployment/agentforge-webhook      3/3  Running  ← dispatcher + queue-watcher + observer
deployment/agentforge-registry     1/1  Running  ← docker registry v2
deployment/agentforge-github-mcp   1/1  Running  ← GitHub MCP server v1.0.3 :8080
deployment/agentforge-postgres     1/1  Running  ← Postgres 16-alpine observability DB
deployment/agentforge-webui        1/1  Running  ← FastAPI dashboard (dashboard.k8s.local)
```

### CronJobs (suspended templates)

```
cronjob/agentforge-architect   SUSPEND=true
cronjob/agentforge-coder       SUSPEND=true
cronjob/agentforge-reviewer    SUSPEND=true
cronjob/agentforge-tester      SUSPEND=true
cronjob/agentforge-ops         SUSPEND=true
```

### PVCs

```
agentforge-memory     Bound  10Gi  RWX  nfs          ← shared agent memory
agentforge-registry   Bound  20Gi  RWO  local-path   ← registry images
agentforge-postgres   Bound  5Gi   RWO  local-path   ← observability DB
```

### Ingress

```
webhook.k8s.local  → dispatcher :8080   (working)
registry excluded  → uses NodePort :30500 directly
```

### Secrets Required

```bash
kubectl create secret generic anthropic-api-key \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-xxx -n agentforge

kubectl create secret generic webhook-secret \
  --from-literal=WEBHOOK_SECRET=your-secret -n agentforge
```

---

## Agent Container Image

- **Registry:** Local `192.168.100.11:30500/claude-agent` (HTTPS, self-signed CA trusted on all nodes)
- **Base:** `node:20-slim`
- **Runtime:** Claude Code CLI (`@anthropic-ai/claude-code`)
- **User:** `agent` (UID 1001) — required by Claude Code security check
- **Built with:** Podman in WSL

### Build and Push

```bash
cd KubernetesHyperVLab/claude-agent/claude-agent-image
podman build -t claude-agent:latest .
podman tag claude-agent:latest docker.io/pdawson1983/claude-agent:latest
podman push docker.io/pdawson1983/claude-agent:latest
```

---

## Pipeline Flow

```
User submits task (curl or web UI)
         ↓
webhook.k8s.local (nginx ingress → dispatcher pod)
         ↓
dispatcher generates task_id (YYYYMMDD-HHMMSS-xxxx)
dispatcher writes payload to /memory/tasks/<task-id>/inbox/<jobname>.json
dispatcher creates architect Job (injects TASK_ID env var via dry-run+apply)
         ↓
Architect pod starts (docker.io/pdawson1983/claude-agent:latest)
  - reads /memory/tasks/<task-id>/inbox/
  - reads /agent/CLAUDE.md (general instructions, baked into image — auto-read by Claude Code)
  - reads /memory/CLAUDE.md if present (optional shared project context)
  - calls Claude Code CLI (prompt includes resolved MEMORY_BASE path)
  - writes spec to /memory/tasks/<task-id>/specs/
  - writes /memory/tasks/<task-id>/queue/coder.json
  - exits 0
         ↓
queue-watcher sidecar detects /memory/tasks/<task-id>/queue/coder.json
enriches payload with task_id, POSTs "architect.complete" to dispatcher
dispatcher extracts task_id, creates Coder Job with TASK_ID env var
         ↓
dispatcher creates Coder Job
         ↓
Coder → Tester → Reviewer → Ops  (same pattern)
```

### Memory Layout

```
/memory/                          ← NFS PVC, mounted by all pods
├── tasks/
│   └── <task-id>/                ← isolated per pipeline run (YYYYMMDD-HHMMSS-xxxx)
│       ├── inbox/                ← dispatcher writes architect payload here
│       ├── specs/                ← architect writes specs here
│       ├── workspace/            ← coder writes code here
│       ├── reviews/              ← reviewer writes reviews here
│       ├── deployments/          ← ops writes deployment artifacts here
│       ├── queue/                ← inter-agent trigger files for this task
│       │   ├── coder.json        ← triggers coder
│       │   ├── tester.json       ← triggers tester
│       │   ├── reviewer.json     ← triggers reviewer
│       │   ├── ops.json          ← triggers ops
│       │   └── active/           ← queue-watcher moves trigger here before dispatch
│       └── logs/                 ← agent output logs for this task
└── CLAUDE.md                     ← global project context (all agents read this)
```

---

## What's Working

- [x] Hyper-V cluster (3 nodes, all Ready)
- [x] Flannel CNI
- [x] MetalLB load balancer
- [x] nginx ingress
- [x] NFS storage (ReadWriteMany for agent memory)
- [x] local-path storage (registry PVC)
- [x] Helm chart deploying cleanly
- [x] Webhook dispatcher running and receiving events
- [x] HMAC signature validation
- [x] Dispatcher writing payloads to /memory/inbox/
- [x] CronJob templates spawning agent Jobs on demand
- [x] Docker Hub image pulling correctly
- [x] Architect agent running end to end (Claude Code called, spec written, coder triggered)
- [x] Queue-watcher sidecar chaining pipeline (architect.complete → coder confirmed 2026-05-07)
- [x] Full pipeline run confirmed end-to-end: Architect → Coder → Tester → Reviewer → Ops (2026-05-07)
- [x] Worker LVM volumes expanded (10GB → 17GB; were causing ephemeral storage evictions)
- [x] Claude.ai Max credentials support (mount secret instead of API key — see helm values)
- [x] Agent behaviour decoupled from Helm (general instructions baked into image via agent-base.md — see ADR-006)
- [x] Pipeline smoke test script (scripts/pipeline-test.sh — mock + haiku modes)
- [x] Switched to versioned image tags + IfNotPresent pull policy (eliminates Docker Hub rate limit risk)
- [x] Fixed agent pod false-Error on NFS trigger file permission denied (cleanup now non-fatal)
- [x] Switched cluster to Claude Max credentials (claude-credentials secret, enabled in values.yaml)
- [x] pipeline-test.sh --mock passing 12/12 (zero tokens, full 5-agent chain validated)
- [x] pipeline-test.sh --haiku passing 6/7 (architect→coder→tester→reviewer chains with real Claude; tester timeout known issue)
- [x] Task-scoped memory namespacing: /memory/tasks/<task-id>/ per run — prevents stale data accumulation and enables concurrent tasks (2026-05-09, image 20260509-022526, mock 14/14)
- [x] Task metadata: task.json written per run with event, title, created_at, status (2026-05-09)
- [x] Task ID returned in webhook HTTP 200 response body (2026-05-09)
- [x] Tester agent timeout increased 300s → 600s (2026-05-09)
- [x] MCP extensibility pattern: GitHub MCP server running in-cluster (ghcr.io/github/github-mcp-server v1.0.3, HTTP transport :8080); architect grants per-agent access via mcpServers array in queue files (2026-05-10, ADR-011)
- [x] entrypoint.sh reads mcpServers from trigger payload, writes ~/.claude/settings.json before Claude Code starts (2026-05-10, image 20260510-024218)
- [x] Mermaid diagrams: cluster topology, agent flow, MCP pattern, WSL connectivity (2026-05-10, K8s HyperV Lab Documents/diagrams/)
- [x] System named AgentForge (2026-05-10)
- [x] .claude/settings.json allowlist: kubectl get/logs/describe, helm template/list, aws read-only commands (2026-05-10)
- [x] pipeline-test.sh --mock passing 14/14 with image 20260510-024218 (2026-05-10)
- [x] Credential auto-refresh script: scripts/refresh-credentials.sh checks expiresAt, runs claude auth login only if within 2h, recreates K8s secret (2026-05-10)
- [x] Agent CronJob securityContext enforced at K8s level: runAsUser/runAsGroup/fsGroup/runAsNonRoot: true on all 5 agents via helper in _helpers.tpl (2026-05-10)
- [x] Git repo integration: repoUrl in task payload flows to architect; coder clones, branches agentforge/<task-id>, pushes; ops creates PR; GITHUB_TOKEN injected into agent pods; git auth via URL rewrite in entrypoint.sh (2026-05-10, image 20260510-113504, mock 14/14)
- [x] First real end-to-end pipeline run: architect→coder→tester→reviewer→ops all succeeded against pdawson1983/testrepo; PR #1 opened by ops via GitHub REST API; total duration 361s (2026-05-10)
- [x] Per-agent maxTurns (architect:20 coder:50 tester:40 reviewer:25 ops:30); global.maxTurns=0 uses per-agent, --set global.maxTurns=N overrides all (2026-05-10)
- [x] Persistent entrypoint logging: log() tees to NFS logs/<role>-entrypoint.log; exit_code in task.json; last 30 lines of Claude output appended on failure (2026-05-10, image 20260510-131545)
- [x] Postgres observability DB: pipeline_runs + agent_runs tables; observer sidecar polls /memory/telemetry/ and imports completed runs; repo_url added to task.json; telemetry write-order bug fixed (2026-05-10, image 20260510-212544)
- [x] Resource naming deduplicated: claude-agents-claude-agents-* → agentforge-* (fullnameOverride, RESOURCE_PREFIX env var for dispatcher, agentforge/role labels)
- [x] Namespace migrated: claude-agents → agentforge; all scripts, docs, label selectors updated; mock 14/14 in agentforge namespace (2026-05-10)
- [x] WSL route persistence validated: task WSL-K8s-Route confirmed working at logon; gap documented (mid-session restart workaround: schtasks.exe /Run /TN "\\WSL-K8s-Route")
- [x] Web UI (dashboard.k8s.local): dashboard, submit with plain-English pipeline mode + Agent Instructions textarea, task detail with live auto-refresh, approval gate page (2026-05-11, chart 0.8.0)
- [x] Context field → task-scoped CLAUDE.md: dispatcher writes /memory/tasks/<id>/CLAUDE.md from submit form; all agents read it before starting (2026-05-11)
- [x] Live task view: dispatcher GET /task/<id> endpoint proxies NFS task.json; task detail auto-refreshes every 5s for in-progress runs (2026-05-11)
- [x] Dashboard auto-refresh every 15s; "< 1s" for sub-second durations (2026-05-11)

---

## What's Next

- [x] Task metadata registry: /memory/tasks/<task-id>/task.json written on creation (task_id, event, title, created_at, status) — queryable via kubectl exec (2026-05-09)
- [x] Task ID in webhook response body: confirmed present as `task_id` field in HTTP 200 JSON (2026-05-09)
- [x] Tester timeout: bumped from 300s → 600s in values.yaml (2026-05-09)
- [x] Control plane LVM verified — filesystem already 43G, 17% used, no expansion needed (2026-05-09)
- [x] MCP extensibility pattern: GitHub MCP server deployed, running, mock 14/14 verified (2026-05-10, ADR-011)
- [x] Git repo integration: repoUrl payload field, GITHUB_TOKEN injected, git URL rewrite in entrypoint.sh, branch naming agentforge/<task-id>, agent-base.md updated (2026-05-10)
- [x] Public repo push: ops created PR #1 on pdawson1983/testrepo via GitHub REST API (2026-05-10)
- [x] Observability data layer: Postgres deployed, pipeline_runs + agent_runs tables, observer sidecar auto-imports telemetry files (2026-05-10)
- [ ] System self-improvement loop: `system.improve` event routes to architect with this repo as target; ops opens a PR; data layer provides the signal for what to improve
- [x] Phase 1 run telemetry: entrypoint.sh writes per-agent timing + status to task.json; completed/failed runs archived to /memory/telemetry/<task-id>.json (2026-05-09)
- [x] Web UI built: dashboard, submit (context textarea→task CLAUDE.md), task detail, approval gate (2026-05-11)
- [ ] Token consumption: capture tokens_input/tokens_output per agent; show on dashboard and task detail
- [ ] Agent Instructions wizard: simple mode (current textarea) + guided wizard with Goal/Constraints/Acceptance Criteria sections
- [ ] Feedback-triggered rebuild: `pipeline.feedback` event accepts a structured observation, routes to architect to propose a fix through the full pipeline including image rebuild
- [ ] CI/CD scope: external GitHub Actions → webhook integration (future)
- [x] Agent CronJob securityContext: runAsUser/runAsGroup/fsGroup 1001, runAsNonRoot: true on all 5 agents (2026-05-10)
- [x] Local registry working with TLS (self-signed CA, system trust store, containerd 2.2.1) — agents pull from 192.168.100.11:30500 (2026-05-09)
- [ ] Add human approval gate between Reviewer and Ops
- [ ] Add Tekton for more complex pipeline orchestration

---

## Known Issues / Technical Debt

**⚠ CRITICAL — Dispatcher must NOT write to queue/ for non-architect agents.**
Writing `queue/coder.json` (or any downstream trigger file) from the dispatcher
causes the queue-watcher to re-fire the same event on its next 5-second poll,
spawning infinite jobs. Only the architect gets an `inbox/` write. All other
agents read from `queue/active/<role>.json` written by the previous agent.
This bug caused 100+ runaway pods on 2026-05-07 and required a manual
`kubectl scale deployment --replicas=0` to stop. Fixed in dispatcher.yaml.
See ADR-005.

**Local registry TLS setup (2026-05-09)** — containerd 2.x CRI image service
requires HTTPS for registry pulls. Registry now serves TLS (self-signed cert,
SAN: all three node IPs). CA cert installed in system trust store on all nodes
(`/usr/local/share/ca-certificates/lab-registry-ca.crt`). Transfer plugin and
CRI images plugin both have `config_path = '/etc/containerd/certs.d'`.
Push from WSL: `podman push 192.168.100.11:30500/claude-agent:<tag> --tls-verify=false`
TLS key material: `/tmp/registry-tls/` on WSL (not committed — regenerate if lost).

**CronJob as template pattern** — agent CronJobs use `schedule: "0 0 31 2 *"`
(Feb 31 — never fires) and `suspend: true` as a permanent template source.
The dispatcher uses `kubectl create job --from cronjob/` to spawn instances.

**WSL route persistence (validated 2026-05-10)** — task `WSL-K8s-Route` runs at Windows
logon and adds the route dynamically. Gap: doesn't fire on mid-session WSL restarts.
Workaround: `schtasks.exe /Run /TN "\\WSL-K8s-Route"` from WSL.

**registry-tls secret not persisted** — the `registry-tls` K8s secret is not in git and
is lost on namespace migration. Recreate from `/tmp/registry-tls/` on WSL:
```bash
kubectl create secret tls registry-tls \
  --cert=/tmp/registry-tls/tls.crt --key=/tmp/registry-tls/tls.key -n agentforge
```
If `/tmp/registry-tls/` is gone, regenerate with `scripts/node-setup/generate-registry-tls.sh`.

**Queue-watcher signing** — the queue-watcher signs outbound events with
WEBHOOK_SECRET via HMAC. If the secret is empty, signing is skipped.

**Trigger file race condition (fixed)** — queue-watcher moves trigger files to
`/memory/tasks/<task-id>/queue/active/<role>.json` before dispatching the event.
`entrypoint.sh` checks `queue/<role>.json` first, then falls back to `queue/active/<role>.json`
(both relative to MEMORY_BASE). See ADR-004 in the knowledge base.

**Worker LVM volumes** — Ubuntu installer left workers with 10GB LV on 20GB disks.
Expanded online with `lvextend + resize2fs` (no downtime). Control plane confirmed
fine (43G filesystem, 17% used — no gap).

**GitHub PAT needs rotation (2026-05-10)** — the token was entered in a conversation
transcript. Rotate at github.com/settings/tokens, then:
```bash
kubectl delete secret github-token -n agentforge
kubectl create secret generic github-token \
  --from-literal=GITHUB_TOKEN="$(cat ~/.config/agentforge/github-token)" -n agentforge
```
Token stored at `~/.config/agentforge/github-token` (mode 600, outside repo).

**Task isolation implemented (2026-05-09)** — each run gets its own `/memory/tasks/<task-id>/`
directory. TASK_ID is generated by the dispatcher, directories are pre-created with 0o777
(dispatcher runs as root, agent as UID 1001), and TASK_ID is injected into Job specs via
dry-run+apply. Old flat `/memory/inbox/`, `/memory/specs/` etc. are no longer written.

**Podman + Docker Hub manifest deduplication on WSL2** — `podman build --no-cache`
produces a new local image ID but the pushed manifest config hash may match a prior
push, meaning Docker Hub serves the old image to nodes even though `:latest` was
re-pushed. Root cause: layer content hashes match the prior build. Fix: always push
with a unique version tag (e.g. `YYYYMMDD-HHMMSS`) and pin `values.yaml` to that
tag. Use `pullPolicy: IfNotPresent` so nodes cache after first pull. See ADR-007.
Verify image content before pushing:
`podman run --rm --entrypoint grep claude-agent:latest -c "AGENT_MOCK" /agent/entrypoint.sh`

**NFS trigger file ownership — pod false-Error (fixed)** — the queue-watcher sidecar
writes trigger files to `/memory/queue/active/` as a different UID than the agent
user (1001). `rm -f` on cleanup failed with Permission denied, causing `set -euo pipefail`
to exit the pod non-zero even though all work completed successfully. Fixed in
entrypoint.sh: cleanup failure is now logged as a warning and does not fail the pod.

**Per-role Helm ConfigMap instructions removed (ADR-006)** — agent behaviour is no
longer controlled by Helm. General instructions are in `agent-base.md` (baked into
image). Project-specific conventions go in the workspace `CLAUDE.md` written by the
architect. Changing agent behaviour now requires an image rebuild and push.

---

## Key Commands

```bash
# Fire a test event
PAYLOAD='{"event": "issue.opened", "title": "Add hello world endpoint"}'
SECRET=$(kubectl get secret webhook-secret -n agentforge \
  -o jsonpath='{.data.WEBHOOK_SECRET}' | base64 -d)
SIG="sha256=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)"
curl -X POST http://webhook.k8s.local \
  -H "Content-Type: application/json" \
  -H "X-Event-Type: issue.opened" \
  -H "X-Hub-Signature-256: $SIG" \
  -d "$PAYLOAD"

# Watch pipeline
kubectl get pods -n agentforge -w
kubectl logs -n agentforge -l app.kubernetes.io/name=webhook-dispatcher -c dispatcher -f
kubectl logs -n agentforge -l app.kubernetes.io/name=webhook-dispatcher -c queue-watcher -f
kubectl logs -n agentforge -l agentforge/role=architect -f

# Inspect memory
kubectl exec -n agentforge \
  $(kubectl get pod -n agentforge -l app.kubernetes.io/name=webhook-dispatcher -o name) \
  -c dispatcher -- find /memory -type f

# Upgrade chart
helm upgrade claude-agents . -n agentforge

# Build and push image — full versioned tag workflow (see ADR-007)
cd KubernetesHyperVLab/claude-agent/claude-agent-image
VERSION_TAG="$(date -u +%Y%m%d-%H%M%S)"
podman build --no-cache --build-arg BUILD_DATE="${VERSION_TAG}" -t claude-agent:latest .

# Verify the change is in the image before pushing
podman run --rm --entrypoint grep claude-agent:latest -c "TASK_ID" /agent/entrypoint.sh

# Push to local registry (--tls-verify=false because self-signed cert)
podman tag claude-agent:latest 192.168.100.11:30500/claude-agent:${VERSION_TAG}
podman push 192.168.100.11:30500/claude-agent:${VERSION_TAG} --tls-verify=false

# Update values.yaml image.tag to $VERSION_TAG, then upgrade
cd KubernetesHyperVLab/helm/claude-agents-v6
helm upgrade claude-agents . -n agentforge

# Refresh Claude.ai Max credentials (expire ~every 24h)
./scripts/refresh-credentials.sh           # login only if expiring within 2h
./scripts/refresh-credentials.sh --force   # always login
./scripts/refresh-credentials.sh --check   # print expiry, no changes

# Inspect a specific task run
TASK_ID=<task-id>
kubectl exec -n agentforge \
  $(kubectl get pod -n agentforge -l app.kubernetes.io/name=webhook-dispatcher -o name | head -1) \
  -c dispatcher -- find /memory/tasks/${TASK_ID} -type f

# Fire a task with a GitHub repo (git repo integration)
PAYLOAD='{"event": "issue.opened", "title": "Add hello endpoint", "repoUrl": "https://github.com/owner/repo"}'
SECRET=$(kubectl get secret webhook-secret -n agentforge \
  -o jsonpath='{.data.WEBHOOK_SECRET}' | base64 -d)
SIG="sha256=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)"
curl -X POST http://webhook.k8s.local \
  -H "Content-Type: application/json" \
  -H "X-Event-Type: issue.opened" \
  -H "X-Hub-Signature-256: $SIG" \
  -d "$PAYLOAD"

# Pipeline smoke test (zero tokens)
cd KubernetesHyperVLab
./scripts/pipeline-test.sh --mock

# Pipeline smoke test (real Claude, Haiku, minimal tokens)
./scripts/pipeline-test.sh --haiku

# Use Claude.ai Max credentials instead of API key
claude auth login   # run once in WSL to populate ~/.claude/.credentials.json
kubectl create secret generic claude-credentials \
  --from-file=.credentials.json=$HOME/.claude/.credentials.json \
  -n agentforge
# Then set global.claudeCredentials.enabled=true in values.yaml and helm upgrade

# Test with mock mode via helm flag (without modifying values.yaml)
helm upgrade claude-agents . -n agentforge --set global.mockMode=true
helm upgrade claude-agents . -n agentforge  # restore defaults

# GitHub MCP server — recreate token secret after PAT rotation
kubectl delete secret github-token -n agentforge
kubectl create secret generic github-token \
  --from-literal=GITHUB_TOKEN="$(cat ~/.config/agentforge/github-token)" -n agentforge

# Check GitHub MCP server health
kubectl logs -n agentforge -l app.kubernetes.io/name=github-mcp-server --tail=10

# Query Postgres observability DB
kubectl exec -n agentforge \
  $(kubectl get pod -n agentforge -l app.kubernetes.io/name=postgres -o name) \
  -- psql -U agentforge -d agentforge -c \
  "SELECT task_id, status, duration_seconds FROM pipeline_runs ORDER BY created_at DESC LIMIT 10;"

# Per-agent timing averages
kubectl exec -n agentforge \
  $(kubectl get pod -n agentforge -l app.kubernetes.io/name=postgres -o name) \
  -- psql -U agentforge -d agentforge -c \
  "SELECT role, AVG(duration_seconds)::int avg_secs, COUNT(*) runs FROM agent_runs GROUP BY role ORDER BY role;"

# Recreate registry-tls after namespace migration (if lost, regenerate with scripts/node-setup/generate-registry-tls.sh)
kubectl create secret tls registry-tls \
  --cert=/tmp/registry-tls/tls.crt --key=/tmp/registry-tls/tls.key -n agentforge

# Build and push web UI image (versioned tag)
cd KubernetesHyperVLab/claude-agent/web-ui
WEBUI_TAG="$(date -u +%Y%m%d-%H%M%S)"
podman build --no-cache -t agentforge-webui:latest .
podman tag agentforge-webui:latest 192.168.100.11:30500/agentforge-webui:${WEBUI_TAG}
podman push 192.168.100.11:30500/agentforge-webui:${WEBUI_TAG} --tls-verify=false
# Update webui.image.tag in values.yaml to $WEBUI_TAG, then helm upgrade

# Web UI logs
kubectl logs -n agentforge -l app.kubernetes.io/name=webui --tail=20

# Add dashboard.k8s.local to /etc/hosts (WSL + Windows)
# 192.168.100.200 webhook.k8s.local dashboard.k8s.local
```
