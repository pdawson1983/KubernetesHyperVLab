# Runbook: Pipeline Smoke Test

Use this runbook to validate the end-to-end agent pipeline without consuming
significant Claude API tokens. Run after any change to the image, Helm chart,
entrypoint, or agent-base.md.

---

## Prerequisites

- WSL2 environment with kubectl and helm configured
- Route to cluster active: `sudo ip route add 192.168.100.0/24 via 172.24.240.1`
- `webhook.k8s.local` resolving to `192.168.100.200` in `/etc/hosts`
- `webhook-secret` K8s secret exists in `claude-agents` namespace
- Either `anthropic-api-key` secret or `claude-credentials` secret exists (for real mode)
- Chart deployed: `helm status claude-agents -n claude-agents`

---

## Mode 1: Mock Test (zero token cost)

Tests the full infrastructure chain without calling Claude. Each agent writes
pre-canned fixture files and chains to the next. Validates: HMAC, dispatcher,
job creation, NFS I/O, queue-watcher detection, pod scheduling.

**When to run:** after any infrastructure change (Helm chart, values, entrypoint
refactor, image rebuild). Takes ~3–5 minutes.

```bash
cd /mnt/c/Users/pdaws/OneDrive/Desktop/Lab/KubernetesHyperVLab
./scripts/pipeline-test.sh --mock
```

Expected output:
```
  PASS  Pre-flight
  PASS  Chart updated — AGENT_MOCK=true on all agents
  PASS  Webhook accepted (HTTP 200)
  PASS  architect
  PASS  coder
  PASS  tester
  PASS  reviewer
  PASS  ops
  PASS  Spec written by architect
  PASS  Code written by coder
  PASS  Review written by reviewer
  PASS  Deployment artifact written by ops
  PASS  Chart restored

══════════════════════════════════════════════════
  PASSED  12 checks — mode: mock
══════════════════════════════════════════════════
```

Mock artifacts are cleaned up automatically. Use `--keep` to inspect them:
```bash
./scripts/pipeline-test.sh --mock --keep
kubectl exec -n claude-agents \
  $(kubectl get pod -n claude-agents -l app.kubernetes.io/name=webhook-dispatcher -o name | head -1) \
  -c dispatcher -- find /memory -name "mock-*" -type f
```

---

## Mode 2: Haiku Test (minimal token cost)

Runs real Claude invocations using `claude-haiku-4-5-20251001` with max 3 turns
and a deliberately trivial task. Validates: prompt delivery, `/agent/CLAUDE.md`
pickup, agent chaining via Claude-written trigger files. Costs a few cents.

**When to run:** after changes to `agent-base.md` or `entrypoint.sh` that affect
how Claude receives or interprets its instructions. Not needed for every change.

```bash
cd /mnt/c/Users/pdaws/OneDrive/Desktop/Lab/KubernetesHyperVLab
./scripts/pipeline-test.sh --haiku
```

The script temporarily switches the chart to Haiku + 3 turns, runs the test,
then restores `claude-sonnet-4-20250514` + 10 turns automatically.

---

## Options

| Flag | Effect |
|------|--------|
| `--mock` | Zero-token infrastructure test |
| `--haiku` | Real Claude test with Haiku model, 3 max turns |
| `--keep` | Do not clean up memory artifacts after test |
| `--timeout <seconds>` | Override pod wait timeout (default: 300) |

---

## Troubleshooting

**Pre-flight fails: webhook not reachable**
```bash
# Check route
ip route | grep 192.168.100
# Re-add if missing
sudo ip route add 192.168.100.0/24 via 172.24.240.1

# Check ingress
kubectl get ingress -n claude-agents
curl -v http://webhook.k8s.local/healthz
```

**Webhook returns non-200**
```bash
# Check dispatcher is running
kubectl get pods -n claude-agents
# Check dispatcher logs
kubectl logs -n claude-agents \
  -l app.kubernetes.io/name=webhook-dispatcher -c dispatcher --tail=20
```

**Agent pod never appears (times out at architect)**
```bash
# Check if Job was created
kubectl get jobs -n claude-agents
# Check dispatcher created the job
kubectl logs -n claude-agents \
  -l app.kubernetes.io/name=webhook-dispatcher -c dispatcher --tail=30
# Check if CronJob template exists
kubectl get cronjob -n claude-agents
```

**Agent pod fails (non-Succeeded)**
The script prints the last 20 lines of the failed pod's logs automatically.
Common causes:
- `AGENT_ROLE is not set` — CronJob template missing env var (check `helm template`)
- `Neither ANTHROPIC_API_KEY nor claude-credentials...` — missing secret (mock mode
  doesn't need auth; this shouldn't happen in --mock)
- Image pull error — check `kubectl describe pod <pod>` for pull errors

**Chain stops mid-pipeline (e.g., coder completes but tester never starts)**
```bash
# Check queue-watcher is detecting trigger files
kubectl logs -n claude-agents \
  -l app.kubernetes.io/name=webhook-dispatcher -c queue-watcher --tail=30
# Check what's in the queue
kubectl exec -n claude-agents \
  $(kubectl get pod -n claude-agents -l app.kubernetes.io/name=webhook-dispatcher -o name | head -1) \
  -c dispatcher -- find /memory/queue -type f
```

---

## Manual Restore

If the test script fails mid-run and the chart is left in test mode:
```bash
cd /mnt/c/Users/pdaws/OneDrive/Desktop/Lab/KubernetesHyperVLab/helm/claude-agents-v6
helm upgrade claude-agents . -n claude-agents \
  --set global.mockMode=false \
  --set global.maxTurns=10 \
  --set global.model=claude-sonnet-4-20250514
```

---

## Related

- `scripts/pipeline-test.sh` — the test script itself
- ADR-006 — why agent behaviour is now image-governed, not Helm-governed
- Knowledge: `podman-wsl2-build-cache.md` — verify image changes before testing
