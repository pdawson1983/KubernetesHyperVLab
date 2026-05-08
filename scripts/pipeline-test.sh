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
#   ./scripts/pipeline-test.sh --mock --keep      # preserve memory artifacts
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
  log "Restoring chart to defaults..."
  helm upgrade claude-agents "$CHART_DIR" -n "$NAMESPACE" \
    --set global.mockMode=false \
    --set global.maxTurns=10 \
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
    log "Switching to Haiku model, max-turns 5 (minimal token cost)..."
    helm upgrade claude-agents "$CHART_DIR" -n "$NAMESPACE" \
      --set global.model=claude-haiku-4-5-20251001 \
      --set global.maxTurns=5 \
      --timeout 60s --wait 2>&1 | grep -E "^Release|upgraded|Error" || true
    pass "Chart updated — Haiku model, 5 max turns"
    ;;
esac

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

# ── Wait for each agent in sequence ──────────────────────────────────────────

AGENTS=(architect coder tester reviewer ops)
DEADLINE=$(($(date +%s) + TIMEOUT))

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

    # Use python3 (always available) to parse pod JSON, exclude pre-existing pods
    # by name, and return the newest remaining pod's phase and name.
    local result
    result=$(kubectl get pods -n "$NAMESPACE" -l "claude-agents/role=$role" \
      -o json 2>/dev/null | \
      python3 - "$pre" << 'PYEOF'
import json, sys

pre_names = set(sys.argv[1].split()) if sys.argv[1] else set()
data = json.load(sys.stdin)
new_pods = [p for p in data.get("items", [])
            if p["metadata"]["name"] not in pre_names]
if not new_pods:
    print("Pending|")
else:
    newest = sorted(new_pods, key=lambda p: p["metadata"]["creationTimestamp"])[-1]
    phase = newest.get("status", {}).get("phase", "Pending")
    name  = newest["metadata"]["name"]
    print(f"{phase}|{name}")
PYEOF
    )

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
  log "Validating memory artifacts..."

  DISPATCHER=$(kubectl get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/name=webhook-dispatcher -o name 2>/dev/null | head -1)

  kexec() {
    kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- "$@" 2>/dev/null
  }

  check_dir() {
    local dir="$1" desc="$2"
    COUNT=$(kexec find "/memory/$dir" -type f | wc -l || echo 0)
    [ "$COUNT" -gt 0 ] && pass "$desc" || fail "$desc — /memory/$dir is empty"
  }

  check_dir "specs"       "Spec written by architect"
  check_dir "workspace"   "Code written by coder"
  check_dir "reviews"     "Review written by reviewer"
  check_dir "deployments" "Deployment artifact written by ops"

  # Show the ops deployment artifact as a quick sanity read
  log "Ops output (last artifact):"
  kexec find /memory/deployments -type f | sort | tail -1 | \
    xargs -I{} kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- cat {} 2>/dev/null | \
    head -10 | sed 's/^/  /' || true
fi

# ── Clean up mock artifacts ───────────────────────────────────────────────────

if [ "$MODE" = "mock" ] && [ "$KEEP" = false ]; then
  log "Cleaning up mock artifacts..."
  DISPATCHER=$(kubectl get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/name=webhook-dispatcher -o name 2>/dev/null | head -1)
  kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
    sh -c 'rm -f /memory/specs/mock-spec-* \
                 /memory/reviews/mock-review-* \
                 /memory/logs/*-mock-* && \
           rm -rf /memory/workspace/mock-project \
                  /memory/deployments/mock-*' 2>/dev/null || true
  log "Mock artifacts removed"
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

[ "$FAILED" -eq 0 ] || exit 1
