#!/usr/bin/env bash
# =============================================================================
# tests/run-all.sh
# Runs all AgentForge test suites and reports a combined result.
#
# Usage:
#   ./tests/run-all.sh                  # all suites
#   ./tests/run-all.sh --unit           # unit tests only (no cluster needed)
#   ./tests/run-all.sh --helm           # Helm template tests only
#   ./tests/run-all.sh --integration    # dispatcher + web UI HTTP tests
#   ./tests/run-all.sh --behavior       # end-to-end behavioral tests
#   ./tests/run-all.sh --smoke          # original pipeline-test.sh --mock
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${SCRIPT_DIR}/.."

PASS_SUITES=0; FAIL_SUITES=0; SKIP_SUITES=0
MODES="${*:-all}"

suite() {
  local name="$1" cmd="$2"
  echo ""
  echo "════════════════════════════════════════"
  echo "  Suite: ${name}"
  echo "════════════════════════════════════════"
  if eval "$cmd"; then
    PASS_SUITES=$(( PASS_SUITES + 1 ))
    echo "  → Suite PASSED"
  else
    FAIL_SUITES=$(( FAIL_SUITES + 1 ))
    echo "  → Suite FAILED"
  fi
}

skip() {
  local name="$1" reason="$2"
  echo ""
  echo "  SKIP  ${name}: ${reason}"
  SKIP_SUITES=$(( SKIP_SUITES + 1 ))
}

want() {
  local flag="$1"
  [[ "$MODES" == *"all"* || "$MODES" == *"$flag"* ]]
}

check_cluster() {
  kubectl get nodes -n agentforge >/dev/null 2>&1
}

# ── Unit tests (no cluster required) ─────────────────────────────────────

if want "--unit"; then
  suite "Entrypoint unit tests" \
    "bash '${SCRIPT_DIR}/unit/test-entrypoint.sh'"
fi

# ── Helm template tests (no cluster required) ─────────────────────────────

if want "--helm"; then
  suite "Helm template tests" \
    "python3 '${SCRIPT_DIR}/helm/test-helm.py'"
fi

# ── Integration tests (cluster required) ─────────────────────────────────

if want "--integration"; then
  if check_cluster; then
    suite "Dispatcher HTTP tests" \
      "python3 '${SCRIPT_DIR}/unit/test-dispatcher.py'"
    suite "Web UI HTTP tests" \
      "WEBUI_URL=http://dashboard.k8s.local python3 '${SCRIPT_DIR}/unit/test-webui.py'"
  else
    skip "Dispatcher HTTP tests" "cluster not reachable"
    skip "Web UI HTTP tests" "cluster not reachable"
  fi
fi

# ── Behavior tests (cluster required, modifies cluster state briefly) ─────

if want "--behavior"; then
  if check_cluster; then
    suite "Behavioral end-to-end tests" \
      "bash '${SCRIPT_DIR}/behavior/test-behavior.sh'"
  else
    skip "Behavioral tests" "cluster not reachable"
  fi
fi

# ── Smoke test ────────────────────────────────────────────────────────────

if want "--smoke"; then
  if check_cluster; then
    suite "Pipeline smoke test (--mock)" \
      "cd '${ROOT}' && ./scripts/pipeline-test.sh --mock"
  else
    skip "Pipeline smoke test" "cluster not reachable"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════"
echo "  Test Run Complete"
echo "  Passed:  ${PASS_SUITES}"
echo "  Failed:  ${FAIL_SUITES}"
echo "  Skipped: ${SKIP_SUITES}"
echo "════════════════════════════════════════════════════"
[ $FAIL_SUITES -eq 0 ]
