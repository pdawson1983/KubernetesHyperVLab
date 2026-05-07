# claude-agent Container Image

The runtime for all five pipeline agents. Uses Claude Code CLI to autonomously
read instructions, process tasks, write outputs to shared memory, and signal
the next agent in the pipeline.

## Structure

```
claude-agent-image/
├── Dockerfile          # Image definition — node:20-slim + claude-code CLI
├── entrypoint.sh       # Main agent runner — reads config, calls claude, writes output
├── queue-watcher.sh    # Sidecar — watches /memory/queue/ and fires next agent
├── test-local.sh       # Local test script — validates image before pushing
└── README.md           # This file
```

## How It Works

Every agent uses the same image. The role is determined at runtime by:
- `AGENT_ROLE` environment variable (set by Kubernetes)
- `/etc/agent/config.json` (mounted from ConfigMap)
- `/etc/agent/CLAUDE.md` (mounted from ConfigMap — the agent's instructions)

The entrypoint:
1. Reads role config and instructions
2. Finds the trigger payload (`/memory/inbox/` for architect, `/memory/queue/<role>.json` for others)
3. Builds a prompt combining project context + instructions + payload
4. Runs `claude --print --max-turns 10` with that prompt
5. Claude Code autonomously reads/writes `/memory/` as needed
6. Exits when done

## Build and Push

```bash
# Install podman if not already installed
sudo apt-get install -y podman

# Test locally first (calls real API — uses ~$0.01 of credits)
ANTHROPIC_API_KEY=sk-ant-xxx ./test-local.sh

# Build
podman build -t claude-agent:latest .

# Tag for cluster registry
podman tag claude-agent:latest registry.k8s.local/claude-agent:latest

# Push
podman push registry.k8s.local/claude-agent:latest --tls-verify=false

# Verify
curl http://registry.k8s.local/v2/_catalog
# Returns: {"repositories":["claude-agent"]}
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | Yes | — | Your Anthropic API key |
| `AGENT_ROLE` | Yes | — | Agent role (architect/coder/reviewer/tester/ops) |
| `MEMORY_PATH` | No | `/memory` | Path to shared memory volume |
| `MAX_TOKENS` | No | `4096` | Max tokens per API call |
| `AGENT_TIMEOUT` | No | `300` | Seconds before agent is killed |

## Volume Mounts (managed by Helm chart)

| Mount | Source | Description |
|-------|--------|-------------|
| `/memory` | PVC `claude-agents-memory` | Shared state between all agents |
| `/etc/agent/CLAUDE.md` | ConfigMap | Agent role instructions |
| `/etc/agent/config.json` | ConfigMap | Agent role config (triggers, timeouts) |

## Memory Layout

```
/memory/
├── inbox/          ← architect reads trigger from here
├── specs/          ← architect writes specs here
├── workspace/      ← coder writes code here
│   └── tests/      ← tester writes tests here
├── reviews/        ← reviewer writes review here
├── deployments/    ← ops writes deployment log here
├── queue/          ← inter-agent trigger files
│   ├── coder.json      ← architect writes → triggers coder
│   ├── tester.json     ← coder writes → triggers tester
│   ├── reviewer.json   ← tester writes → triggers reviewer
│   └── ops.json        ← reviewer writes → triggers ops
├── logs/           ← all agent output logs
└── CLAUDE.md       ← project context (read by all agents)
```

## Adding a Human Approval Gate

To require human review before an agent runs, add an approval check in `entrypoint.sh`:

```bash
# After finding PAYLOAD_FILE, before running claude:
APPROVAL_FILE="${MEMORY_PATH}/approved/${ROLE}"
if [ ! -f "$APPROVAL_FILE" ]; then
  log "Waiting for human approval at: $APPROVAL_FILE"
  log "Run: touch $APPROVAL_FILE"
  exit 1
fi
```

Then approve from WSL:
```bash
kubectl exec -n claude-agents \
  $(kubectl get pod -n claude-agents -l claude-agents/role=reviewer -o name) \
  -- touch /memory/approved/reviewer
```

## Updating Agent Instructions

Instructions are stored in ConfigMaps, not in the image. Update them without rebuilding:

```bash
# Edit values.yaml: agents.architect.instructions
helm upgrade claude-agents ./claude-agents-v5 -n claude-agents
```

The new instructions are mounted automatically on the next agent run.
