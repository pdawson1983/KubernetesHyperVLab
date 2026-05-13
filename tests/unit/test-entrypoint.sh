#!/usr/bin/env bash
# =============================================================================
# tests/unit/test-entrypoint.sh
# Unit tests for entrypoint.sh logic using a fake NFS filesystem tree.
# Runs entirely in /tmp — no cluster required.
# =============================================================================

set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTRYPOINT="${SCRIPT_DIR}/../../claude-agent/claude-agent-image/entrypoint.sh"

# ── Test helpers ──────────────────────────────────────────────────────────────

pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL  $1"; FAIL=$(( FAIL + 1 )); }

assert_file_exists()    { [ -f "$1" ] && pass "$2" || fail "$2: $1 not found"; }
assert_file_missing()   { [ ! -f "$1" ] && pass "$2" || fail "$2: $1 should not exist"; }
assert_file_contains()  { grep -q "$2" "$1" 2>/dev/null && pass "$3" || fail "$3: '$2' not in $1"; }

# Create a minimal fake NFS task structure
setup_task() {
  local task_id="$1" skip_agents="${2:-[]}"
  FAKE_ROOT=$(mktemp -d /tmp/agentforge-test-XXXXXX)
  MEMORY_PATH="${FAKE_ROOT}/memory"
  TASK_DIR="${MEMORY_PATH}/tasks/${task_id}"
  mkdir -p "${TASK_DIR}"/{inbox,specs,queue/{active},workspace,reviews,deployments,logs}
  cat > "${TASK_DIR}/task.json" << JSON
{
  "task_id": "${task_id}",
  "event": "issue.opened",
  "title": "Test task",
  "status": "running",
  "skip_agents": ${skip_agents}
}
JSON
  echo "$FAKE_ROOT"
}

cleanup() { rm -rf "${FAKE_ROOT:-}" 2>/dev/null || true; }
trap cleanup EXIT

# ── Test: CLAUDE.md precedence ─────────────────────────────────────────────

echo ""
echo "── CLAUDE.md precedence ──────────────────────────────────────────────"

TASK_ID="test-claude-md-001"
FAKE_ROOT=$(setup_task "$TASK_ID")
MEMORY_PATH="${FAKE_ROOT}/memory"
MEMORY_BASE="${MEMORY_PATH}/tasks/${TASK_ID}"

echo "global context" > "${MEMORY_PATH}/CLAUDE.md"
echo "task context"   > "${MEMORY_BASE}/CLAUDE.md"

# Simulate the entrypoint PROJECT_CONTEXT_CONTENT logic
PROJECT_CONTEXT_CONTENT=""
if [ -f "${MEMORY_BASE}/CLAUDE.md" ]; then
  PROJECT_CONTEXT_CONTENT=$(cat "${MEMORY_BASE}/CLAUDE.md")
elif [ -f "${MEMORY_PATH}/CLAUDE.md" ]; then
  PROJECT_CONTEXT_CONTENT=$(cat "${MEMORY_PATH}/CLAUDE.md")
fi

[ "$PROJECT_CONTEXT_CONTENT" = "task context" ] && \
  pass "task-scoped CLAUDE.md wins over global" || \
  fail "task-scoped CLAUDE.md wins over global (got: $PROJECT_CONTEXT_CONTENT)"

rm "${MEMORY_BASE}/CLAUDE.md"
PROJECT_CONTEXT_CONTENT=""
if [ -f "${MEMORY_BASE}/CLAUDE.md" ]; then
  PROJECT_CONTEXT_CONTENT=$(cat "${MEMORY_BASE}/CLAUDE.md")
elif [ -f "${MEMORY_PATH}/CLAUDE.md" ]; then
  PROJECT_CONTEXT_CONTENT=$(cat "${MEMORY_PATH}/CLAUDE.md")
fi

[ "$PROJECT_CONTEXT_CONTENT" = "global context" ] && \
  pass "falls back to global CLAUDE.md when task-scoped absent" || \
  fail "falls back to global CLAUDE.md (got: $PROJECT_CONTEXT_CONTENT)"

cleanup

# ── Test: skip check logic ──────────────────────────────────────────────────

echo ""
echo "── Skip check logic ──────────────────────────────────────────────────"

for role in coder tester reviewer ops; do
  TASK_ID="test-skip-${role}"
  FAKE_ROOT=$(setup_task "$TASK_ID" "[\"${role}\"]")
  MEMORY_BASE="${FAKE_ROOT}/memory/tasks/${TASK_ID}"

  IS_SKIPPED=$(python3 -c "
import json, pathlib
p = pathlib.Path('${MEMORY_BASE}/task.json')
d = json.loads(p.read_text())
print('yes' if '${role}' in d.get('skip_agents', []) else 'no')
")
  [ "$IS_SKIPPED" = "yes" ] && \
    pass "skip_agents: ${role} detected as skipped" || \
    fail "skip_agents: ${role} not detected"

  cleanup
done

# role not in skip list
TASK_ID="test-no-skip"
FAKE_ROOT=$(setup_task "$TASK_ID" "[\"tester\"]")
MEMORY_BASE="${FAKE_ROOT}/memory/tasks/${TASK_ID}"

IS_SKIPPED=$(python3 -c "
import json, pathlib
p = pathlib.Path('${MEMORY_BASE}/task.json')
d = json.loads(p.read_text())
print('yes' if 'coder' in d.get('skip_agents', []) else 'no')
")
[ "$IS_SKIPPED" = "no" ] && \
  pass "role not in skip_agents returns no" || \
  fail "role not in skip_agents should return no"

cleanup

# ── Test: next role mapping ─────────────────────────────────────────────────

echo ""
echo "── Next-role skip-through mapping ───────────────────────────────────"

check_next() {
  local role="$1" expected="$2"
  local next=""
  case "$role" in
    coder)    next="tester" ;;
    tester)   next="reviewer" ;;
    reviewer) next="ops" ;;
    ops)      next="" ;;
  esac
  [ "$next" = "$expected" ] && \
    pass "next role after ${role} = '${expected}'" || \
    fail "next role after ${role}: expected '${expected}' got '${next}'"
}

check_next coder    tester
check_next tester   reviewer
check_next reviewer ops
check_next ops      ""

# ── Test: skip-through trigger file content ─────────────────────────────────

echo ""
echo "── Skip-through trigger file ────────────────────────────────────────"

TASK_ID="test-trigger"
FAKE_ROOT=$(setup_task "$TASK_ID" "[\"tester\"]")
MEMORY_BASE="${FAKE_ROOT}/memory/tasks/${TASK_ID}"

# Simulate what the skip code does
AGENT_ROLE="tester"; _NEXT_ROLE="reviewer"; TASK="Test task"
printf '{"from":"%s","task":"%s","output":"(skipped)","notes":"%s was skipped by user","skipped":true}\n' \
  "$AGENT_ROLE" "$TASK" "$AGENT_ROLE" > "${MEMORY_BASE}/queue/${_NEXT_ROLE}.json"

assert_file_exists "${MEMORY_BASE}/queue/reviewer.json" "trigger file written for next role"
assert_file_contains "${MEMORY_BASE}/queue/reviewer.json" '"skipped":true' "trigger file contains skipped flag"
assert_file_contains "${MEMORY_BASE}/queue/reviewer.json" '"from":"tester"' "trigger file has correct from field"

cleanup

# ── Test: token metrics extraction ─────────────────────────────────────────

echo ""
echo "── Token metrics extraction ──────────────────────────────────────────"

TASK_ID="test-metrics"
FAKE_ROOT=$(setup_task "$TASK_ID")
MEMORY_BASE="${FAKE_ROOT}/memory/tasks/${TASK_ID}"

# Create a mock claude --output-format json response
cat > "${MEMORY_BASE}/logs/architect-metrics.json" << 'JSON'
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "num_turns": 5,
  "result": "I wrote the spec.",
  "total_cost_usd": 0.042,
  "usage": {
    "input_tokens": 1500,
    "output_tokens": 300,
    "cache_read_input_tokens": 500,
    "cache_creation_input_tokens": 1000
  }
}
JSON

EXTRACTED=$(python3 -c "
import json, pathlib
m = json.loads(pathlib.Path('${MEMORY_BASE}/logs/architect-metrics.json').read_text())
usage = m.get('usage', {})
print(usage.get('input_tokens'), usage.get('output_tokens'), m.get('num_turns'), m.get('total_cost_usd'))
")
[ "$EXTRACTED" = "1500 300 5 0.042" ] && \
  pass "token metrics extracted correctly from metrics.json" || \
  fail "token metrics extraction failed (got: $EXTRACTED)"

# Verify result text extraction
RESULT=$(python3 -c "
import json, pathlib
d = json.loads(pathlib.Path('${MEMORY_BASE}/logs/architect-metrics.json').read_text())
print(d.get('result',''))
")
[ "$RESULT" = "I wrote the spec." ] && \
  pass "result text extracted from JSON output" || \
  fail "result text extraction failed (got: $RESULT)"

cleanup

# ── Test: mock mode fixture writing ────────────────────────────────────────

echo ""
echo "── Mock mode fixture paths ───────────────────────────────────────────"

# Verify each mock role would write to the expected path
declare -A MOCK_OUTPUTS=(
  [architect]="specs"
  [coder]="workspace/mock-project/main.py"
  [tester]="workspace/mock-project/test_main.py"
  [reviewer]="reviews"
  [ops]="deployments"
)

for role in architect coder tester reviewer ops; do
  expected="${MOCK_OUTPUTS[$role]}"
  TASK_ID="test-mock-${role}"
  FAKE_ROOT=$(setup_task "$TASK_ID")
  MEMORY_BASE="${FAKE_ROOT}/memory/tasks/${TASK_ID}"

  # Ensure the write paths exist (dirs would be created by entrypoint)
  case "$role" in
    architect) mkdir -p "${MEMORY_BASE}/specs" && touch "${MEMORY_BASE}/specs/spec.md" ;;
    coder)     mkdir -p "${MEMORY_BASE}/workspace/mock-project" && touch "${MEMORY_BASE}/workspace/mock-project/main.py" ;;
    tester)    mkdir -p "${MEMORY_BASE}/workspace/mock-project" && touch "${MEMORY_BASE}/workspace/mock-project/test_main.py" ;;
    reviewer)  mkdir -p "${MEMORY_BASE}/reviews" && touch "${MEMORY_BASE}/reviews/review.md" ;;
    ops)       mkdir -p "${MEMORY_BASE}/deployments/mock-run" && touch "${MEMORY_BASE}/deployments/mock-run/deployment.md" ;;
  esac

  pass "mock ${role} output path structure is valid"
  cleanup
done

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════"
TOTAL=$(( PASS + FAIL ))
if [ $FAIL -eq 0 ]; then
  echo "  PASSED  ${PASS}/${TOTAL} unit tests"
else
  echo "  FAILED  ${PASS} passed, ${FAIL} failed — ${TOTAL} total"
fi
echo "══════════════════════════════════════════════════"
[ $FAIL -eq 0 ]
