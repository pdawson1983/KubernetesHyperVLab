# Agent Container Image

## What This Is

The container image (`docker.io/pdawson1983/claude-agent:latest`) that runs inside
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

```bash
# Always use --no-cache on WSL2 to avoid stale layer cache
podman build --no-cache -t claude-agent:latest .

# Verify the image has expected content before pushing
podman run --rm --entrypoint grep claude-agent:latest -c "AGENT_MOCK" /agent/entrypoint.sh

podman tag claude-agent:latest docker.io/pdawson1983/claude-agent:latest
podman push docker.io/pdawson1983/claude-agent:latest
```

After pushing, new agent Jobs will pull the updated image (`pullPolicy: Always`).

## Entrypoint Flow

1. Validate `AGENT_ROLE` is set
2. Auth check: use `ANTHROPIC_API_KEY` if set; else copy `~/.claude-creds/.credentials.json`
   to `~/.claude/` (Claude.ai Max subscription support)
3. Ensure memory directories exist
4. Find trigger payload:
   - `architect` → most recent file in `/memory/inbox/`
   - all others → `/memory/queue/<role>.json` (falls back to `queue/active/<role>.json`)
5. **If `AGENT_MOCK=true`:** write fixture files for this role, write trigger file, exit 0
6. Build prompt = role identity + payload + `/memory/CLAUDE.md` content (if present)
7. Write prompt to tmpfile, run `timeout $AGENT_TIMEOUT claude --print --max-turns $AGENT_MAX_TURNS --dangerously-skip-permissions`
8. Tee Claude output to `/memory/logs/<role>-output-<timestamp>.log`
9. On success: delete consumed trigger file (non-architect only). Exit 0 on success,
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
| `AGENT_MOCK` | `false` | Helm `global.mockMode` — skip Claude, write fixtures |
| `AGENT_MAX_TURNS` | `10` | Helm `global.maxTurns` — reduced to 3 for Haiku test mode |
| `AGENT_TIMEOUT` | `300` | CronJob template env (per-agent in values.yaml) |
| `MEMORY_PATH` | `/memory` | CronJob template env |
| `HOME` | `/home/agent` | Set explicitly so Claude Code finds credentials correctly |

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
