#!/bin/bash
# =============================================================================
# test-local.sh
# Tests the claude-agent image locally before pushing to the cluster registry.
#
# Usage:
#   chmod +x test-local.sh
#   ANTHROPIC_API_KEY=sk-ant-xxx ./test-local.sh
# =============================================================================

set -euo pipefail

IMAGE="claude-agent:latest"
TEST_DIR=$(mktemp -d /tmp/claude-agent-test-XXXXXX)
AGENT_UID=1001

log() { echo "[test] $*"; }
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; exit 1; }

cleanup() {
  log "Cleaning up..."
  # Use podman unshare to remove dirs owned by agent UID
  podman unshare rm -rf "$TEST_DIR" 2>/dev/null || rm -rf "$TEST_DIR" 2>/dev/null || true
  podman rm -f claude-agent-test 2>/dev/null || true
}
trap cleanup EXIT

# ── Check prerequisites ───────────────────────────────────────────────────────

[ -z "${ANTHROPIC_API_KEY:-}" ] && fail "Set ANTHROPIC_API_KEY before running"
command -v podman >/dev/null || fail "podman not installed"

log "Using test directory: $TEST_DIR"

# ── Build the image ───────────────────────────────────────────────────────────

log "Building image: $IMAGE"
podman build -t "$IMAGE" . || fail "Build failed"
pass "Image built successfully"

# ── Set up test memory layout ─────────────────────────────────────────────────
# Create ALL files first, then chown everything in one shot

mkdir -p \
  "$TEST_DIR/memory/inbox" \
  "$TEST_DIR/memory/specs" \
  "$TEST_DIR/memory/queue" \
  "$TEST_DIR/memory/workspace" \
  "$TEST_DIR/memory/reviews" \
  "$TEST_DIR/memory/deployments" \
  "$TEST_DIR/memory/logs" \
  "$TEST_DIR/agent-config"

# Write ALL files before chown
cat > "$TEST_DIR/memory/inbox/test-task-001.json" << 'EOF'
{
  "event": "issue.opened",
  "title": "Add a hello world endpoint",
  "body": "Create a simple GET /hello endpoint that returns {\"message\": \"Hello, World!\"}",
  "labels": ["feature"],
  "submitted_at": "2026-05-07T00:00:00Z"
}
EOF

cat > "$TEST_DIR/memory/CLAUDE.md" << 'EOF'
# Test Project Context

## Stack
- Node.js REST API
- Express framework
- Tests with Jest

## Conventions
- Routes in /src/routes/
- Tests next to source files as *.test.js
EOF

cat > "$TEST_DIR/agent-config/config.json" << 'EOF'
{
  "role": "architect",
  "maxTokens": 2048,
  "triggers": ["issue.opened"],
  "timeout": 120
}
EOF

cat > "$TEST_DIR/agent-config/CLAUDE.md" << 'EOF'
## Role: Architect Agent

You are a software architect. Analyze the incoming request and produce a clear spec.

## Responsibilities
- Read the incoming request from /memory/inbox/
- Write a concise spec to /memory/specs/spec-001.md
- Write {"ready": true, "spec": "/memory/specs/spec-001.md"} to /memory/queue/coder.json

## Rules
- Keep specs under 200 lines
- Always include: Overview, Components, API contracts, Acceptance criteria
- Never write implementation code
EOF

# Now chown everything in one shot AFTER all files are written
podman unshare chown -R ${AGENT_UID}:${AGENT_UID} "$TEST_DIR/memory"
# agent-config stays root-owned since it's mounted read-only

log "Test environment set up"

# ── Run the architect agent ───────────────────────────────────────────────────

log "Running architect agent (this will call the Anthropic API)..."

podman run --rm \
  --user ${AGENT_UID} \
  --name claude-agent-test \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -e AGENT_ROLE="architect" \
  -e MEMORY_PATH="/memory" \
  -e MAX_TOKENS="2048" \
  -e AGENT_TIMEOUT="120" \
  -v "$TEST_DIR/memory:/memory" \
  -v "$TEST_DIR/agent-config:/etc/agent:ro" \
  "$IMAGE" \
  || fail "Agent container exited with error"

pass "Agent container completed successfully"

# ── Validate outputs ──────────────────────────────────────────────────────────

log "Checking outputs..."

if ls "$TEST_DIR/memory/specs/"*.md 1>/dev/null 2>&1; then
  SPEC_FILE=$(ls "$TEST_DIR/memory/specs/"*.md | head -1)
  SPEC_SIZE=$(wc -c < "$SPEC_FILE")
  pass "Spec written: $SPEC_FILE ($SPEC_SIZE bytes)"
  echo "--- Spec preview (first 20 lines) ---"
  head -20 "$SPEC_FILE" 2>/dev/null || podman unshare cat "$SPEC_FILE"
  echo "---"
else
  fail "No spec file found in $TEST_DIR/memory/specs/"
fi

if [ -f "$TEST_DIR/memory/queue/coder.json" ]; then
  pass "Coder trigger written"
  cat "$TEST_DIR/memory/queue/coder.json" 2>/dev/null || true
else
  fail "No coder trigger at $TEST_DIR/memory/queue/coder.json"
fi

echo ""
echo "================================================"
echo "  All tests passed!"
echo "================================================"
