# Agent Container Image

## What This Is

The container image (`192.168.100.11:30500/claude-agent:<tag>`) that runs inside
every Kubernetes agent Job. All five roles (Architect, Coder, Reviewer, Tester, Ops)
share one image — the role is injected via `AGENT_ROLE` env var. General operating
instructions are baked into the image as `/agent/CLAUDE.md` (see ADR-006).

## Key Files

| File | Purpose |
|------|---------|
| `Dockerfile` | node:20-slim + Claude Code CLI + non-root `agent` user (UID 1001) |
| `agent-base.md` | Baked into image as `/agent/CLAUDE.md` — general pipeline rules, role descriptions, chaining protocol, security rules. Claude Code reads this automatically (WORKDIR is `/agent`). |
| `entrypoint.sh` | Validates auth, finds trigger payload, runs `claude --print` (or mock mode). |
| `queue-watcher.sh` | **Not used inside agent pods.** Runs as a sidecar in the *dispatcher* deployment. |
| `test-local.sh` | Local integration test — spins up architect against a synthetic task using podman. |

## Build and Push

Use versioned tags — never push to `:latest` alone (Docker Hub manifest deduplication
causes nodes to silently run old images). See ADR-007.

```bash
VERSION_TAG="$(date -u +%Y%m%d-%H%M%S)"
podman build --no-cache --build-arg BUILD_DATE="${VERSION_TAG}" -t claude-agent:latest .

# Verify expected content is in the image before pushing
podman run --rm --entrypoint grep claude-agent:latest -c "TASK_ID" /agent/entrypoint.sh

# Push to local registry (self-signed cert — tls-verify=false for push only)
podman tag claude-agent:latest 192.168.100.11:30500/claude-agent:${VERSION_TAG}
podman push 192.168.100.11:30500/claude-agent:${VERSION_TAG} --tls-verify=false
echo "Update values.yaml image.tag to: ${VERSION_TAG}"
```

After pushing: update `global.image.tag` in `helm/claude-agents-v6/values.yaml` and
run `helm upgrade claude-agents . -n claude-agents`. Nodes use `pullPolicy: IfNotPresent`
and cache the image after first pull. Nodes trust the registry via the system CA bundle
(`/usr/local/share/ca-certificates/lab-registry-ca.crt`).

## Entrypoint Flow

1. Validate `AGENT_ROLE` and `TASK_ID` are set
2. Set `MEMORY_BASE=/memory/tasks/$TASK_ID` — all reads/writes use this path
3. Auth check: use `ANTHROPIC_API_KEY` if set; else copy `~/.claude-creds/.credentials.json`
   to `~/.claude/` (Claude.ai Max subscription support)
4. Create task-scoped directories under `$MEMORY_BASE` (`mkdir -p inbox specs queue ...`)
5. Find trigger payload:
   - `architect` → most recent file in `$MEMORY_BASE/inbox/`
   - all others → `$MEMORY_BASE/queue/<role>.json` (falls back to `queue/active/<role>.json`)
6. **If `AGENT_MOCK=true`:** write fixture files, write trigger file (to `$MEMORY_BASE/queue/`), exit 0
7. **MCP setup:** read `mcpServers` array from trigger payload; for each named server, look up `MCP_<NAME>_URL` env var and write `~/.claude/settings.json`. Skipped if array is absent or empty. See ADR-011.
8. **Git config:** if `GITHUB_TOKEN` is set, configure git URL rewrite so `git clone/push https://github.com/` authenticates automatically. Sets `AgentForge` as git user name/email.
9. Build prompt = role identity + **resolved MEMORY_BASE path** + payload + `/memory/CLAUDE.md` (if present)
10. Write prompt to tmpfile, run `timeout $AGENT_TIMEOUT claude --print --max-turns $AGENT_MAX_TURNS --dangerously-skip-permissions`
9. Tee Claude output to `$MEMORY_BASE/logs/<role>-output-<timestamp>.log`
10. On success: delete consumed trigger file (non-architect only). Exit 0 on success,
    124 on timeout, else Claude's exit code.

Note: Claude Code reads `/agent/CLAUDE.md` automatically because WORKDIR is `/agent`.
The prompt is kept minimal — role identity, payload, optional project context.

## Critical Constraints

- **Non-root user is mandatory.** Claude Code refuses to run as root. The `agent`
  user (UID 1001) is created in the Dockerfile.
- **`--dangerously-skip-permissions`** is required in headless mode.
- **Prompt is written to a tmpfile** (`mktemp`) to avoid shell escaping issues.
- Agents do NOT chain themselves. The queue-watcher sidecar detects the trigger file
  Claude writes and POSTs back to the dispatcher, which spawns the next Job.

## Environment Variables

| Variable | Default | Set By |
|----------|---------|--------|
| `ANTHROPIC_API_KEY` | — | K8s Secret `anthropic-api-key` (optional if using Max credentials) |
| `AGENT_ROLE` | — | CronJob template env (label-derived via fieldRef) |
| `TASK_ID` | — | Injected per-run by dispatcher via dry-run+apply (see ADR-009) |
| `AGENT_MOCK` | `false` | Helm `global.mockMode` — skip Claude, write fixtures |
| `AGENT_MAX_TURNS` | `10` | Helm `global.maxTurns` — reduced to 3 for Haiku test mode |
| `AGENT_TIMEOUT` | `300` | CronJob template env (per-agent in values.yaml; tester=600s) |
| `MEMORY_PATH` | `/memory` | NFS mount point; task-scoped base is `$MEMORY_PATH/tasks/$TASK_ID` |
| `HOME` | `/home/agent` | Set explicitly so Claude Code finds credentials correctly |
| `MCP_GITHUB_URL` | — | Injected by Helm when `mcp.servers.github.enabled: true`; HTTP endpoint for GitHub MCP server |
| `MCP_GITHUB_ENABLED` | — | Set to `"true"` by Helm alongside `MCP_GITHUB_URL` |
| `GITHUB_TOKEN` | — | Injected by Helm when `mcp.servers.github.enabled: true`; used by entrypoint.sh to configure git authentication |

## Changing Agent Behaviour

Agent instructions are **baked into the image** via `agent-base.md`. To change
how all agents behave:

1. Edit `agent-base.md`
2. `podman build --no-cache -t claude-agent:latest .`
3. Verify: `podman run --rm --entrypoint cat claude-agent:latest /agent/CLAUDE.md`
4. Push and deploy new Jobs

Project-specific conventions are set by the architect writing a `CLAUDE.md` into
the workspace directory. Helm controls no agent behaviour (see ADR-006).

## Troubleshooting

```bash
# Check what a running/completed agent actually did
kubectl logs -n claude-agents -l claude-agents/role=architect -f

# Inspect memory after a run
kubectl exec -n claude-agents \
  $(kubectl get pod -n claude-agents -l app.kubernetes.io/name=webhook-dispatcher -o name | head -1) \
  -c dispatcher -- find /memory -type f

# Verify image content before pushing
podman run --rm --entrypoint grep claude-agent:latest -c "AGENT_MOCK" /agent/entrypoint.sh

# Run smoke test (zero tokens)
./scripts/pipeline-test.sh --mock
```

Common failures:
- `AGENT_ROLE is not set` — CronJob template missing env (check `helm template`)
- `Neither ANTHROPIC_API_KEY nor claude-credentials...` — missing secret
- `No payload found in /memory/inbox/` — architect ran before dispatcher wrote inbox
- Claude exits 1 — check `/memory/logs/<role>-output-*.log`; usually rate limit or malformed prompt
