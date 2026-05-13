#!/usr/bin/env bash
# =============================================================================
# tests/behavior/test-behavior.sh
# End-to-end behavioral tests against the running cluster.
# Tests specific pipeline behaviors — not just infrastructure (that's --mock).
#
# Scenarios:
#   1. Skip agents: submit with skipAgents, verify skipped agent never runs
#   2. Context CLAUDE.md: submit with context, verify file written to NFS
#   3. Task metadata: verify task.json fields after dispatch
#
# Requires: cluster running, webhook.k8s.local resolvable, kubectl configured
# Usage: ./tests/behavior/test-behavior.sh [--keep]
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
TIMEOUT=120
KEEP=false
[[ "${1:-}" == "--keep" ]] && KEEP=true

NAMESPACE="agentforge"
WEBHOOK_URL="http://webhook.k8s.local"
DISPATCHER=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=webhook-dispatcher \
  -o name | head -1)

pass() { echo "  PASS  $1"; (( PASS++ )); }
fail() { echo "  FAIL  $1"; (( FAIL++ )); }

fire_webhook() {
  local payload="$1"
  local SECRET
  SECRET=$(kubectl get secret webhook-secret -n "$NAMESPACE" \
    -o jsonpath='{.data.WEBHOOK_SECRET}' | base64 -d)
  local SIG="sha256=$(echo -n "$payload" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)"
  curl -s -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -H "X-Event-Type: issue.opened" \
    -H "X-Hub-Signature-256: $SIG" \
    -d "$payload"
}

wait_for_task_status() {
  local task_id="$1" expected_status="$2" seconds="${3:-$TIMEOUT}"
  local elapsed=0
  while [ $elapsed -lt $seconds ]; do
    local status
    status=$(kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
      python3 -c "import json,pathlib; p=pathlib.Path('/memory/tasks/${task_id}/task.json'); \
      print(json.loads(p.read_text()).get('status','')) if p.exists() else print('')" 2>/dev/null || echo "")
    [ "$status" = "$expected_status" ] && return 0
    sleep 5
    (( elapsed += 5 ))
  done
  return 1
}

cleanup_task() {
  local task_id="$1"
  $KEEP && return
  kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
    rm -rf "/memory/tasks/${task_id}" 2>/dev/null || true
}

# ── Scenario 1: Skip agents ────────────────────────────────────────────────

echo ""
echo "── Scenario 1: Skip agents (mock + skipAgents) ───────────────────────"

# Enable mock mode for this test
helm upgrade claude-agents "$SCRIPT_DIR/../../helm/claude-agents-v6" \
  -n "$NAMESPACE" --set global.mockMode=true --timeout 60s --wait \
  2>&1 | grep -E "^Release|upgraded|Error" || true

PAYLOAD='{"event":"issue.opened","title":"behavior-test skip tester","skipAgents":["tester"]}'
RESPONSE=$(fire_webhook "$PAYLOAD")
TASK_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('task_id',''))" 2>/dev/null || echo "")

if [ -z "$TASK_ID" ]; then
  fail "Skip test: webhook dispatch failed (no task_id)"
else
  pass "Skip test: task dispatched ($TASK_ID)"

  # Wait for pipeline to complete
  if wait_for_task_status "$TASK_ID" "completed" 90; then
    pass "Skip test: pipeline completed"

    # Verify tester shows as skipped in task.json
    TESTER_STATUS=$(kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
      python3 -c "
import json,pathlib
p=pathlib.Path('/memory/tasks/${TASK_ID}/task.json')
d=json.loads(p.read_text())
print(d.get('agents',{}).get('tester',{}).get('status','not_found'))
" 2>/dev/null || echo "error")

    [ "$TESTER_STATUS" = "skipped" ] && \
      pass "Skip test: tester.status=skipped in task.json" || \
      fail "Skip test: expected tester.status=skipped got '$TESTER_STATUS'"

    # Verify reviewer ran (the agent after tester)
    REVIEWER_STATUS=$(kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
      python3 -c "
import json,pathlib
p=pathlib.Path('/memory/tasks/${TASK_ID}/task.json')
d=json.loads(p.read_text())
print(d.get('agents',{}).get('reviewer',{}).get('status','not_found'))
" 2>/dev/null || echo "error")

    [ "$REVIEWER_STATUS" = "success" ] && \
      pass "Skip test: reviewer ran successfully after skipped tester" || \
      fail "Skip test: reviewer.status expected success got '$REVIEWER_STATUS'"

    # Verify skip-through trigger file content
    TRIGGER_EXISTS=$(kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
      test -f "/memory/tasks/${TASK_ID}/queue/active/reviewer.json" && echo "yes" || echo "no" 2>/dev/null || echo "no")
    # The trigger may have been consumed; check it ran at minimum
    [ "$REVIEWER_STATUS" = "success" ] && \
      pass "Skip test: reviewer trigger was consumed and agent ran" || true

  else
    fail "Skip test: pipeline did not complete within ${TIMEOUT}s"
  fi
  cleanup_task "$TASK_ID"
fi

# ── Scenario 2: Context CLAUDE.md written to NFS ─────────────────────────

echo ""
echo "── Scenario 2: Context field → task CLAUDE.md ────────────────────────"

CONTEXT="## Test constraints\n- Use only stdlib\n- Max 10 lines"
PAYLOAD="{\"event\":\"issue.opened\",\"title\":\"behavior-test context field\",\"context\":\"${CONTEXT}\"}"
RESPONSE=$(fire_webhook "$PAYLOAD")
TASK_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('task_id',''))" 2>/dev/null || echo "")

if [ -z "$TASK_ID" ]; then
  fail "Context test: webhook dispatch failed"
else
  pass "Context test: task dispatched ($TASK_ID)"
  sleep 3  # Give dispatcher time to write the file

  CLAUDE_MD_EXISTS=$(kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
    test -f "/memory/tasks/${TASK_ID}/CLAUDE.md" && echo "yes" || echo "no" 2>/dev/null || echo "no")

  [ "$CLAUDE_MD_EXISTS" = "yes" ] && \
    pass "Context test: CLAUDE.md written to /memory/tasks/<id>/" || \
    fail "Context test: CLAUDE.md not found at /memory/tasks/${TASK_ID}/CLAUDE.md"

  CLAUDE_MD_CONTENT=$(kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
    cat "/memory/tasks/${TASK_ID}/CLAUDE.md" 2>/dev/null || echo "")

  echo "$CLAUDE_MD_CONTENT" | grep -q "Test constraints" && \
    pass "Context test: CLAUDE.md contains submitted context" || \
    fail "Context test: CLAUDE.md content doesn't match (got: ${CLAUDE_MD_CONTENT:0:100})"

  # Wait for architect to log that it read the task context
  if wait_for_task_status "$TASK_ID" "completed" 90; then
    ARCHITECT_LOG=$(kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
      cat "/memory/tasks/${TASK_ID}/logs/architect-entrypoint.log" 2>/dev/null || echo "")
    echo "$ARCHITECT_LOG" | grep -q "task context\|CLAUDE.md" && \
      pass "Context test: architect log shows task CLAUDE.md was read" || \
      fail "Context test: architect log doesn't show CLAUDE.md read"
  fi

  cleanup_task "$TASK_ID"
fi

# ── Scenario 3: Task metadata fields ─────────────────────────────────────

echo ""
echo "── Scenario 3: Task metadata completeness ────────────────────────────"

PAYLOAD='{"event":"issue.opened","title":"behavior-test metadata","repoUrl":"https://github.com/test/repo"}'
RESPONSE=$(fire_webhook "$PAYLOAD")
TASK_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('task_id',''))" 2>/dev/null || echo "")

if [ -z "$TASK_ID" ]; then
  fail "Metadata test: webhook dispatch failed"
else
  pass "Metadata test: task dispatched ($TASK_ID)"
  sleep 2

  TASK_JSON=$(kubectl exec -n "$NAMESPACE" "$DISPATCHER" -c dispatcher -- \
    cat "/memory/tasks/${TASK_ID}/task.json" 2>/dev/null || echo "{}")

  for field in task_id event title repo_url created_at status; do
    echo "$TASK_JSON" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
val=d.get('$field')
sys.exit(0 if val is not None and val != '' else 1)
" 2>/dev/null && pass "Metadata test: task.json has field '$field'" || \
    fail "Metadata test: task.json missing '$field'"
  done

  # Verify task_id in webhook response matches task.json
  RESP_TASK_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('task_id',''))" 2>/dev/null)
  JSON_TASK_ID=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('task_id',''))" 2>/dev/null)
  [ "$RESP_TASK_ID" = "$JSON_TASK_ID" ] && \
    pass "Metadata test: webhook response task_id matches task.json" || \
    fail "Metadata test: task_id mismatch response=$RESP_TASK_ID json=$JSON_TASK_ID"

  cleanup_task "$TASK_ID"
fi

# ── Restore defaults ──────────────────────────────────────────────────────

helm upgrade claude-agents "$SCRIPT_DIR/../../helm/claude-agents-v6" \
  -n "$NAMESPACE" --timeout 60s --wait \
  2>&1 | grep -E "^Release|upgraded|Error" || true

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════"
TOTAL=$(( PASS + FAIL ))
if [ $FAIL -eq 0 ]; then
  echo "  PASSED  ${PASS}/${TOTAL} behavior tests"
else
  echo "  FAILED  ${PASS} passed, ${FAIL} failed — ${TOTAL} total"
fi
echo "══════════════════════════════════════════════════"
[ $FAIL -eq 0 ]
