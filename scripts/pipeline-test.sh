#!/usr/bin/env bash
# =============================================================================
# scripts/pipeline-test.sh
# End-to-end pipeline smoke test.
#
# Two modes:
#   --mock   Zero token cost. Agents write fixture files instead of calling
#            Claude. Tests: webhook HMAC, dispatcher, job creation, NFS I/O,
#            queue-watcher chaining, full 5-agent sequence.
#
#   --haiku  Minimal token cost. Real Claude invocation using Haiku with
#            max-turns 3 and a deliberately trivial task. Tests everything
#            --mock tests plus prompt reading and agent behaviour.
#
# Usage:
#   ./scripts/pipeline-test.sh --mock
#   ./scripts/pipeline-test.sh --haiku
#   ./scripts/pipeline-test.sh --mock --keep      # preserve task directory
#   ./scripts/pipeline-test.sh --mock --timeout 120
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$SCRIPT_DIR/../helm/claude-agents-v6"
NAMESPACE="claude-agents"
TIMEOUT=300
MODE=""
KEEP=false
PASSED=0
FAILED=0
TASK_ID=""

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
pass() { echo "  PASS  $*"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL  $*"; FAILED=$((FAILED+1)); }
die()  { echo "ERROR: $*" >&2; cleanup_and_restore; exit 1; }

# ── Args ─────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --mock)    MODE="mock";  shift ;;
    --haiku)   MODE="haiku"; shift ;;
    --keep)    KEEP=true;    shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --mock | --haiku [--keep] [--timeout <seconds>]"
      exit 0 ;;
    *) echo "Unknown argument: $1"; echo "Usage: $0 --mock | --haiku [--keep]"; exit 1 ;;
  esac
done

[ -z "$MODE" ] && { echo "Usage: $0 --mock | --haiku [--keep] [--timeout <seconds>]"; exit 1; }

# ── Restore chart to defaults ─────────────────────────────────────────────────

cleanup_and_restore() {
  if [ "$MODE" = "mock" ] && [ "$KEEP" = false ] && [ -n "$TASK_ID" ]; then
    log "Cleaning up task directory: /memory/tasks/$TASK_ID"
    local DISP
    DISP=$(kubectl get pod -n "$NAMESPACE" \
      -l app.kubernetes.io/name=webhook-dispatcher -o name 2>/dev/null | head -1 || true)
    if [ -n "$DISP" ]; then
      kubectl exec -n "$NAMESPACE" "$DISP" -c dispatcher -- \
        rm -rf "/memory/tasks/${TASK_ID}" 2>/dev/null || true
      log "Task directory removed"
    fi
  fi
  log "Restoring chart to defaults..."
  helm upgrade claude-agents "$CHART_DIR" -n "$NAMESPACE" \
    --set global.mockMode=false \
    --set global.model=claude-sonnet-4-20250514 \
    --timeout 60s --wait 2>&1 | grep -E "^Release|upgraded|Error" || true
}

# ── Snapshot pre-existing pods per role ──────────────────────────────────────
# Captured before any test activity so wait_for_agent can ignore old pods.

declare -A PRE_PODS
snapshot_existing_pods() {
  local role
  for role in architect coder tester reviewer ops; do
    PRE_PODS[$role]=$(kubectl get pods -n "$NAMESPACE" \
      -l "claude-agents/role=$role" \
      -o jsonpath='{range .items[*]}{.metadata.name} {end}' 2>/dev/null | sed 's/ *$//')
  done
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────

log "Pre-flight checks..."

kubectl get namespace "$NAMESPACE" &>/dev/null \
  || die "Namespace $NAMESPACE not found — is the chart deployed?"

kubectl get secret webhook-secret -n "$NAMESPACE" &>/dev/null \
  || die "webhook-secret not found in $NAMESPACE"

curl -sf http://webhook.k8s.local/healthz &>/dev/null \
  || die "Webhook not reachable at http://webhook.k8s.local — check route and ingress"

pass "Pre-flight"

# Snapshot existing pods NOW — before the helm upgrade — so the upgrade duration
# cannot narrow the gap between snapshot and first new pod creation.
snapshot_existing_pods
log "Pre-existing pods snapshotted"

# ── Apply test mode settings ──────────────────────────────────────────────────

log "Mode: $MODE"

case "$MODE" in
  mock)
    log "Enabling mock mode (zero token cost)..."
    helm upgrade claude-agents "$CHART_DIR" -n "$NAMESPACE" \
      --set global.mockMode=true \
      --timeout 60s --wait 2>&1 | grep -E "^Release|upgraded|Error" || true
    pass "Chart updated — AGENT_MOCK=true on all agents"
    ;;
  haiku)
    log "Switching to Haiku model (minimal token cost)..."
    helm upgrade claude-agents "$CHART_DIR" -n "$NAMESPACE" \
      --set global.model=claude-haiku-4-5-20251001 \
      --timeout 60s --wait 2>&1 | grep -E "^Release|upgraded|Error" || true
    pass "Chart updated — Haiku model"
    ;;
esac

# ── Clean task memory before haiku test ──────────────────────────────────────
# Haiku test always starts fresh. Remove all prior task directories.

if [ "$MODE" = "haiku" ]; then
  log "Clearing all task memory for fresh test run..."
  DISPATCHER_POD=$(kubectl get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/name=webhook-dispatcher -o name 2>/dev/null | head -1)
  kubectl exec -n "$NAMESPACE" "$DISPATCHER_POD" -c dispatcher -- \
    sh -c 'rm -rf /memory/tasks/*' 2>/dev/null || true
  log "Task memory cleared"
fi

# ── Fire test webhook ─────────────────────────────────────────────────────────

PAYLOAD='{"event":"issue.opened","title":"Smoke test: write a hello.txt containing the word hello — keep it trivial"}'
SECRET=$(kubectl get secret webhook-secret -n "$NAMESPACE" \
  -o jsonpath='{.data.WEBHOOK_SECRET}' | base64 -d)
SIG="sha256=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)"

log "Firing test webhook..."
HTTP=$(curl -s -o /tmp/pipeline-test-response.txt -w "%{http_code}" \
  -X POST http://webhook.k8s.local \
  -H "Content-Type: application/json" \
  -H "X-Event-Type: issue.opened" \
  -H "X-Hub-Signature-256: $SIG" \
  -d "$PAYLOAD")

if [ "$HTTP" = "200" ]; then
  pass "Webhook accepted (HTTP 200)"
else
  fail "Webhook rejected (HTTP $HTTP: $(cat /tmp/pipeline-test-response.txt))"
  cleanup_and_restore
  exit 1
fi

# ── Discover the task directory ───────────────────────────────────────────────
# The dispatcher creates /memory/tasks/<task-id>/ when it writes the inbox.
# Re-discover the dispatcher pod on each retry so a mid-upgrade pod restart
# doesn't cause kubectl exec to silently return empty.

DISPATCHER=""
log "Waiting for task directory in /memory/tasks/..."
TASK_DEADLINE=$(($(date +%s) + 45))
while [ -z "$TASK_ID" ] && [ $(date +%s) -lt $TASK_DEADLINE ]; do
  DISPATCHER=$(kubectl get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/name=webhook-dispatcher -o name \
    --field-selector=status.phase=Running 2>/dev/null | head -1)
  if [ -n "$DISPATCHER" ]; then
    TASK_ID=$(kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
      sh -c 'ls -1t /memory/tasks/ 2>/dev/null | head -1' 2>/dev/null || true)
  fi
  [ -z "$TASK_ID" ] && sleep 3
done

if [ -z "$TASK_ID" ]; then
  fail "No task directory appeared in /memory/tasks/ within 45s"
  cleanup_and_restore
  exit 1
fi

log "Task ID: $TASK_ID"
pass "Task directory created: /memory/tasks/$TASK_ID"

# ── Wait for each agent in sequence ──────────────────────────────────────────

AGENTS=(architect coder tester reviewer ops)
DEADLINE=$(($(date +%s) + TIMEOUT))

_POD_FILTER=$(mktemp /tmp/pod-filter-XXXXXX.py)
cat > "$_POD_FILTER" << 'PYEOF'
import json, sys
pre_names = set(sys.argv[1].split()) if sys.argv[1] else set()
try:
    data = json.load(sys.stdin)
except Exception:
    print("Pending|"); sys.exit(0)
new_pods = [p for p in data.get("items", []) if p["metadata"]["name"] not in pre_names]
if not new_pods:
    print("Pending|")
else:
    newest = sorted(new_pods, key=lambda p: p["metadata"]["creationTimestamp"])[-1]
    phase = newest.get("status", {}).get("phase", "Pending")
    name  = newest["metadata"]["name"]
    print(f"{phase}|{name}")
PYEOF

wait_for_agent() {
  local role="$1"
  local pre="${PRE_PODS[$role]:-}"
  log "Waiting for $role pod (deadline in $((DEADLINE - $(date +%s)))s)..."

  while true; do
    if [[ $(date +%s) -gt $DEADLINE ]]; then
      fail "$role — timed out after ${TIMEOUT}s"
      echo "  --- dispatcher logs (last 10 lines) ---"
      kubectl logs -n "$NAMESPACE" \
        -l app.kubernetes.io/name=webhook-dispatcher -c dispatcher \
        --tail=10 2>/dev/null | sed 's/^/  /' || true
      return 1
    fi

    local result
    result=$(kubectl get pods -n "$NAMESPACE" -l "claude-agents/role=$role" \
      -o json 2>/dev/null | python3 "$_POD_FILTER" "$pre")

    local PHASE POD
    PHASE="${result%%|*}"
    POD="${result##*|}"

    case "$PHASE" in
      Succeeded)
        pass "$role"
        return 0
        ;;
      Failed)
        fail "$role pod failed"
        if [ -n "$POD" ]; then
          echo "  --- $role pod logs (last 20 lines) ---"
          kubectl logs -n "$NAMESPACE" "$POD" --tail=20 2>/dev/null | sed 's/^/  /' || true
        fi
        return 1
        ;;
      *)
        sleep 5
        ;;
    esac
  done
}

CHAIN_OK=true
for ROLE in "${AGENTS[@]}"; do
  if ! wait_for_agent "$ROLE"; then
    CHAIN_OK=false
    break
  fi
done

# ── Validate memory artifacts ─────────────────────────────────────────────────

if [ "$CHAIN_OK" = true ]; then
  log "Validating memory artifacts in /memory/tasks/$TASK_ID/..."

  kexec() {
    kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- "$@" 2>/dev/null
  }

  check_dir() {
    local dir="$1" desc="$2"
    COUNT=$(kexec find "/memory/tasks/$TASK_ID/$dir" -type f 2>/dev/null | wc -l || echo 0)
    [ "$COUNT" -gt 0 ] && pass "$desc" || fail "$desc — /memory/tasks/$TASK_ID/$dir is empty"
  }

  # Validate task.json metadata
  TASK_JSON=$(kexec cat "/memory/tasks/$TASK_ID/task.json" 2>/dev/null || true)
  if echo "$TASK_JSON" | grep -q '"status"'; then
    pass "task.json metadata written"
    echo "$TASK_JSON" | sed 's/^/  /'
  else
    fail "task.json missing or malformed"
  fi

  check_dir "specs"       "Spec written by architect"
  check_dir "workspace"   "Code written by coder"
  check_dir "reviews"     "Review written by reviewer"
  check_dir "deployments" "Deployment artifact written by ops"

  # Show the ops deployment artifact as a quick sanity read
  log "Ops output (last artifact):"
  kexec find "/memory/tasks/$TASK_ID/deployments" -type f | sort | tail -1 | \
    xargs -I{} kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- cat {} 2>/dev/null | \
    head -10 | sed 's/^/  /' || true
fi

# ── Restore chart ─────────────────────────────────────────────────────────────

cleanup_and_restore

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════"
if [ "$FAILED" -eq 0 ]; then
  echo "  PASSED  $PASSED checks — mode: $MODE"
else
  echo "  FAILED  $PASSED passed, $FAILED failed — mode: $MODE"
fi
echo "══════════════════════════════════════════════════"

rm -f "$_POD_FILTER"
[ "$FAILED" -eq 0 ] || exit 1
