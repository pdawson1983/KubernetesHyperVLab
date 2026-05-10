# Agent Task Flow

How a task moves through the AgentForge pipeline from webhook to completed deployment.

```mermaid
sequenceDiagram
    actor User
    participant Ingress as nginx-ingress<br/>webhook.k8s.local
    participant Dispatcher as Dispatcher<br/>(Python HTTP)
    participant NFS as NFS Volume<br/>/memory/tasks/<task-id>/
    participant QW as Queue-Watcher<br/>(sidecar)
    participant K8s as Kubernetes API

    User->>Ingress: POST / (HMAC-signed JSON)
    Ingress->>Dispatcher: forward request
    Dispatcher->>Dispatcher: validate HMAC signature
    Dispatcher->>NFS: mkdir tasks/<task-id>/{inbox,specs,queue,...}
    Dispatcher->>NFS: write inbox/<job>.json (payload + task_id)
    Dispatcher->>NFS: write task.json (metadata, status=running)
    Dispatcher->>K8s: kubectl create job --from cronjob/architect
    Dispatcher-->>User: 200 {"task_id": "..."}

    Note over K8s: Architect pod starts (TASK_ID injected)

    K8s->>NFS: agent reads inbox/*.json
    K8s->>NFS: agent writes specs/spec.md
    K8s->>NFS: agent writes queue/coder.json {"mcpServers":["github"]}

    QW->>NFS: poll queue/ every 5s — detects coder.json
    QW->>NFS: move coder.json → queue/active/coder.json
    QW->>Dispatcher: POST architect.complete + task_id

    Dispatcher->>K8s: kubectl create job --from cronjob/coder

    Note over K8s: Coder pod starts — entrypoint reads mcpServers,<br/>writes ~/.claude/settings.json, invokes Claude Code

    K8s->>NFS: coder reads specs/, writes workspace/
    K8s->>NFS: coder writes queue/tester.json

    Note over QW,K8s: Same pattern repeats:<br/>Coder → Tester → Reviewer → Ops

    K8s->>NFS: ops writes deployments/deployment.yaml
    NFS->>NFS: task.json status → completed<br/>archived to /memory/telemetry/<task-id>.json
```

## Queue File Contract

Each agent writes a JSON trigger file to `<task-memory-base>/queue/<next-role>.json`
to hand off to the next stage. The `mcpServers` field is optional — only include
servers the next agent actually needs.

```json
{
  "from": "architect",
  "task": "brief description of what was done",
  "output": "/memory/tasks/<task-id>/specs/spec.md",
  "notes": "anything the next agent needs to know",
  "mcpServers": ["github"]
}
```

The queue-watcher moves the file to `queue/active/` before dispatching, preventing
double-fire if the watcher polls again before the job starts.
