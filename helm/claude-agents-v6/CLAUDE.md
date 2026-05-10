# Helm Chart: claude-agents v6 (Active)

**Version:** 0.6.0 | **Release name:** `claude-agents` | **Namespace:** `claude-agents`
**Current revision:** 12 | **Image tag:** `20260510-024218`
**Image registry:** `192.168.100.11:30500` (local HTTPS, self-signed CA trusted on all nodes)
**Auth:** Claude Max credentials (`claude-credentials` secret, `claudeCredentials.enabled: true`)

This is the live chart. Do not edit files in `helm/archive/`.

## Template Overview

```
templates/
├── _helpers.tpl          — shared functions (labels, env, volumes, image)
├── namespace.yaml        — creates claude-agents namespace
├── project-context.yaml  — comment-only (removed, see ADR-006)
├── agents/
│   ├── configmaps.yaml   — comment-only (per-role instructions removed, see ADR-006)
│   └── jobs.yaml         — CronJob templates (suspend=true, schedule=Feb 31)
├── rbac/rbac.yaml        — ServiceAccount + Role (create Jobs, read CronJobs/Pods)
├── storage/pvc.yaml      — NFS PVC (10Gi RWX); annotated keep-on-uninstall
├── ingress/ingress.yaml  — webhook only (registry uses NodePort :30500 directly)
├── registry/registry.yaml — docker registry v2, NodePort :30500, local-path PVC 20Gi
├── mcp/github-mcp-server.yaml — GitHub MCP server Deployment + ClusterIP Service :8080
└── webhook/dispatcher.yaml — 2-container Deployment: dispatcher (Python) + queue-watcher (bash)
```

## The CronJob-as-Template Pattern

Agent Jobs are **not** created by Kubernetes scheduling. The CronJobs use
`schedule: "0 0 31 2 *"` (Feb 31, never fires) and `suspend: true` as permanent
templates. The dispatcher runs:

```bash
kubectl create job <name> --from=cronjob/<cronjob-name> -n claude-agents
```

## Dispatcher Python Server (inline in dispatcher.yaml)

Handles `GET /healthz`, `GET /readyz`, and `POST /` (HMAC validation → job creation).

TRIGGER_MAP:
```
issue.opened / issue.labeled  → architect
architect.complete            → coder
coder.complete                → tester
tester.complete / pr.opened   → reviewer
reviewer.approved / deployment.requested → ops
```

To change event routing, edit `webhook/dispatcher.yaml` (the Python dict).

## Key values.yaml Sections

| Section | What to change here |
|---------|---------------------|
| `global.image.tag` | Versioned tag after each push (format: `YYYYMMDD-HHMMSS`); never use `latest` |
| `global.image.repository` | `192.168.100.11:30500/claude-agent` (local registry, HTTPS) |
| `global.model` | Claude model for all agents |
| `global.maxTurns` | Max agentic turns per invocation (default 10; set to 3 for Haiku test) |
| `global.mockMode` | `true` = agents write fixtures instead of calling Claude (zero token test) |
| `global.claudeCredentials.enabled` | `true` = use Claude.ai Max credentials (currently active); `false` = use API key |
| `global.claudeCredentials.secretName` | Name of the K8s secret holding `.credentials.json` (default: `claude-credentials`) |
| `global.resources` | Default CPU/memory for all agent pods |
| `agents.<role>.maxTokens` | Per-role token limit |
| `agents.<role>.timeout` | Per-role timeout in seconds (tester: 600s, others: 300s) |
| `memory.storageClass` | Must match a StorageClass with ReadWriteMany (currently "nfs") |
| `registry.nodePort` | NodePort for registry (30500) |
| `registry.tls.enabled` | `true` = mount TLS cert into registry pod (currently active) |
| `registry.tls.secretName` | K8s secret name holding `tls.crt` + `tls.key` (default: `registry-tls`) |
| `mcp.enabled` | Master switch for all MCP servers (default: `true`) |
| `mcp.servers.github.enabled` | Deploy GitHub MCP server (default: `false`; requires `github-token` secret) |
| `mcp.servers.github.tokenSecret` | K8s secret name for `GITHUB_TOKEN` (default: `github-token`) |
| `mcp.servers.github.args` | CLI args for github-mcp-server; must be `["http", "--port", "8080"]` |

**Note:** `agents.<role>.instructions` and `projectContext` no longer exist. Agent
behaviour is governed by the image (`agent-base.md`), not Helm. See ADR-006.

## Upgrade Workflow

```bash
# From helm/claude-agents-v6/:
helm upgrade claude-agents . -n claude-agents

# Dry-run:
helm upgrade claude-agents . -n claude-agents --dry-run

# Render templates locally:
helm template claude-agents . -n claude-agents

# Test flag overrides (no values.yaml edit needed):
helm upgrade claude-agents . -n claude-agents --set global.mockMode=true
helm upgrade claude-agents . -n claude-agents --set global.model=claude-haiku-4-5-20251001 --set global.maxTurns=3
```

## Required Secrets (not managed by Helm)

```bash
# Option A: Anthropic API key (not currently used — API key disabled)
kubectl create secret generic anthropic-api-key \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-xxx -n claude-agents

# Option B: Claude.ai Max credentials — CURRENTLY ACTIVE
# Run 'claude auth login' in WSL first to populate ~/.claude/.credentials.json
kubectl create secret generic claude-credentials \
  --from-file=.credentials.json=$HOME/.claude/.credentials.json \
  -n claude-agents
# global.claudeCredentials.enabled is already true in values.yaml
# NOTE: credentials expire — re-run 'claude auth login' and recreate secret periodically

# Always required:
kubectl create secret generic webhook-secret \
  --from-literal=WEBHOOK_SECRET=your-secret -n claude-agents

# GitHub MCP server (required when mcp.servers.github.enabled: true)
# Token stored at ~/.config/agentforge/github-token (mode 600, outside repo)
kubectl create secret generic github-token \
  --from-literal=GITHUB_TOKEN="$(cat ~/.config/agentforge/github-token)" -n claude-agents
# ⚠ Rotate PAT at github.com/settings/tokens if exposed in conversation transcript
```

## Storage Notes

- **NFS PVC (`claude-agents-memory`)** — `helm.sh/resource-policy: keep` prevents
  deletion on `helm uninstall`. Agent memory persists across chart versions.
- **local-path PVC (`claude-agents-registry`)** — node-local, deleted on uninstall.
  Registry images must be re-pushed after reinstall.

## Debugging

```bash
# Dispatcher logs
kubectl logs -n claude-agents -l app.kubernetes.io/name=webhook-dispatcher -c dispatcher -f

# Queue-watcher logs
kubectl logs -n claude-agents -l app.kubernetes.io/name=webhook-dispatcher -c queue-watcher -f

# Jobs
kubectl get jobs -n claude-agents

# Memory
kubectl exec -n claude-agents \
  $(kubectl get pod -n claude-agents -l app.kubernetes.io/name=webhook-dispatcher -o name | head -1) \
  -c dispatcher -- find /memory -type f

# GitHub MCP server logs
kubectl logs -n claude-agents -l app.kubernetes.io/name=github-mcp-server --tail=20

# Pipeline smoke test
cd ../.. && ./scripts/pipeline-test.sh --mock
```
