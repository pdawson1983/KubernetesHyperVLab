# claude-agents Helm Chart

A Kubernetes-native multi-agent Claude Code pipeline. Five specialized agents
(Architect, Coder, Reviewer, Tester, Ops) triggered by webhook events, sharing
a persistent memory volume to pass context between stages.

## Architecture

```
Webhook Event
     │
     ▼
┌─────────────────┐
│ Dispatcher Pod  │  ← always running, NodePort :30080
│ (Deployment)    │
└────────┬────────┘
         │ kubectl create job
         ▼
┌─────────────────────────────────────────────────────┐
│                  Kubernetes Jobs                     │
│                                                     │
│  [Architect] → [Coder] → [Tester] → [Reviewer]     │
│                                          │          │
│                                       [Ops]         │
└─────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────┐
│  Shared PVC     │  ← /memory — all agents read/write here
│  (10Gi)         │
└─────────────────┘
```

## Prerequisites

- Kubernetes cluster (v1.29+)
- Helm 3
- `kubectl` configured
- Anthropic API key

## Quick Start

```bash
# 1. Create secrets (do this before helm install)
kubectl create namespace claude-agents

kubectl create secret generic anthropic-api-key \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-your-key \
  -n claude-agents

kubectl create secret generic webhook-secret \
  --from-literal=WEBHOOK_SECRET=your-webhook-secret \
  -n claude-agents

# 2. Install the chart
helm install claude-agents . -n claude-agents

# 3. Send a test event
curl -X POST http://192.168.100.11:30080 \
  -H "Content-Type: application/json" \
  -H "X-Event-Type: issue.opened" \
  -d '{"event": "issue.opened", "title": "Add login page"}'

# 4. Watch the pipeline
kubectl get pods -n claude-agents -w
```

## Agent Pipeline Flow

| Agent | Trigger Events | Reads From | Writes To |
|-------|---------------|------------|-----------|
| Architect | `issue.opened`, `issue.labeled` | `/memory/inbox/` | `/memory/specs/`, `/memory/queue/coder.json` |
| Coder | `architect.complete` | `/memory/specs/` | `/memory/workspace/` |
| Tester | `coder.complete` | `/memory/workspace/` | `/memory/workspace/tests/` |
| Reviewer | `tester.complete`, `pr.opened` | `/memory/workspace/` | `/memory/reviews/` |
| Ops | `reviewer.approved` | `/memory/reviews/` | `/memory/deployments/` |

## Configuration

### Disable an agent

```yaml
# my-values.yaml
agents:
  ops:
    enabled: false
```

### Change memory size

```yaml
memory:
  size: 20Gi
  storageClass: managed-premium   # for AKS
```

### Override agent instructions

```yaml
agents:
  architect:
    instructions: |
      ## Role: Architect Agent
      Your custom instructions here...
```

### Use a different model per agent

Add to your values:
```yaml
agents:
  architect:
    model: claude-opus-4-20250514   # use Opus for complex design work
  coder:
    model: claude-sonnet-4-20250514  # Sonnet for implementation
```

### Change the webhook port

```yaml
webhook:
  nodePort: 30090
```

## Directory Structure

```
claude-agents/
├── Chart.yaml                    # Chart metadata
├── values.yaml                   # All defaults (edit this)
├── README.md                     # This file
└── templates/
    ├── _helpers.tpl               # Shared template functions
    ├── namespace.yaml             # Namespace creation
    ├── project-context.yaml       # CLAUDE.md ConfigMap (shared)
    ├── NOTES.txt                  # Post-install instructions
    ├── agents/
    │   ├── configmaps.yaml        # Per-agent instruction ConfigMaps
    │   └── jobs.yaml              # Per-agent Job templates
    ├── rbac/
    │   └── rbac.yaml              # ServiceAccount, Role, RoleBinding
    ├── storage/
    │   └── pvc.yaml               # Shared memory PVC
    └── webhook/
        └── dispatcher.yaml        # Webhook dispatcher Deployment + Service
```

## Monitoring

```bash
# All resources in the namespace
kubectl get all -n claude-agents

# Watch jobs as they're created
kubectl get jobs -n claude-agents -w

# Agent logs
kubectl logs -n claude-agents -l claude-agents/role=architect -f
kubectl logs -n claude-agents -l claude-agents/role=coder -f

# Dispatcher logs
kubectl logs -n claude-agents -l app.kubernetes.io/name=webhook-dispatcher -f

# Memory contents
kubectl exec -n claude-agents \
  $(kubectl get pod -n claude-agents -l app.kubernetes.io/name=webhook-dispatcher -o name) \
  -- find /memory -type f
```

## Upgrading

```bash
helm upgrade claude-agents . -n claude-agents -f my-values.yaml
```

## Uninstalling

```bash
# Removes everything EXCEPT the memory PVC (preserved by annotation)
helm uninstall claude-agents -n claude-agents

# To also delete memory (WARNING: loses all agent state)
kubectl delete pvc -n claude-agents -l app.kubernetes.io/managed-by=Helm
```

## Next Steps

- Replace the inline dispatcher script with a proper container image
- Add GitHub webhook integration (use `X-Hub-Signature-256` header)
- Add Tekton for more complex pipeline orchestration
- Add network policies to restrict inter-agent communication
- Set up Prometheus metrics on the dispatcher
