#!/bin/bash
# =============================================================================
# entrypoint.sh
# Main agent entrypoint. Runs inside every agent container.
#
# Flow:
#   1. Read role from /etc/agent/config.json
#   2. Find the trigger payload (inbox for architect, queue for others)
#   3. Build a prompt combining project context + role instructions + payload
#   4. Run Claude Code with that prompt
#   5. Claude Code reads/writes /memory/ autonomously
#   6. Exit with Claude Code's exit code
# =============================================================================

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$AGENT_ROLE] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

# ── Validate environment ──────────────────────────────────────────────────────

[ -z "${ANTHROPIC_API_KEY:-}" ] && die "ANTHROPIC_API_KEY is not set"
[ -z "${AGENT_ROLE:-}" ] && die "AGENT_ROLE is not set"

MEMORY_PATH="${MEMORY_PATH:-/memory}"
MAX_TOKENS="${MAX_TOKENS:-4096}"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-300}"
CONFIG_FILE="/etc/agent/config.json"
INSTRUCTIONS_FILE="/etc/agent/CLAUDE.md"
PROJECT_CONTEXT="${MEMORY_PATH}/CLAUDE.md"

log "Starting agent role=$AGENT_ROLE timeout=${AGENT_TIMEOUT}s"

# ── Read role configuration ───────────────────────────────────────────────────

[ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
[ -f "$INSTRUCTIONS_FILE" ] || die "Instructions file not found: $INSTRUCTIONS_FILE"

ROLE=$(jq -r '.role' "$CONFIG_FILE")
log "Role confirmed: $ROLE"

# ── Ensure memory directories exist ──────────────────────────────────────────

mkdir -p \
  "${MEMORY_PATH}/inbox" \
  "${MEMORY_PATH}/specs" \
  "${MEMORY_PATH}/queue" \
  "${MEMORY_PATH}/queue/active" \
  "${MEMORY_PATH}/workspace" \
  "${MEMORY_PATH}/reviews" \
  "${MEMORY_PATH}/deployments" \
  "${MEMORY_PATH}/logs"

# ── Find the trigger payload ──────────────────────────────────────────────────
# Architect reads from /memory/inbox/ (written by the dispatcher)
# All other agents read from /memory/queue/<role>.json (written by previous agent)

PAYLOAD_FILE=""

if [ "$ROLE" = "architect" ]; then
  # Find the most recent inbox file
  PAYLOAD_FILE=$(ls -t "${MEMORY_PATH}/inbox/"*.json 2>/dev/null | head -1 || true)
  [ -z "$PAYLOAD_FILE" ] && die "No payload found in ${MEMORY_PATH}/inbox/"
else
  PAYLOAD_FILE="${MEMORY_PATH}/queue/${ROLE}.json"
  if [ ! -f "$PAYLOAD_FILE" ]; then
    # Queue-watcher moves the trigger to queue/active/ before dispatching the
    # event so the file survives pod scheduling and image pull delays.
    PAYLOAD_FILE="${MEMORY_PATH}/queue/active/${ROLE}.json"
    [ -f "$PAYLOAD_FILE" ] || die "No trigger file found at queue/${ROLE}.json or queue/active/${ROLE}.json"
    log "Reading trigger from active/: $PAYLOAD_FILE"
  fi
fi

log "Reading payload from: $PAYLOAD_FILE"
PAYLOAD=$(cat "$PAYLOAD_FILE")

# ── Build the prompt ──────────────────────────────────────────────────────────

# Read project context if available
PROJECT_CONTEXT_CONTENT=""
if [ -f "$PROJECT_CONTEXT" ]; then
  PROJECT_CONTEXT_CONTENT=$(cat "$PROJECT_CONTEXT")
fi

# Read role instructions
INSTRUCTIONS=$(cat "$INSTRUCTIONS_FILE")

# Construct the full prompt
PROMPT=$(cat << PROMPTEOF
# Project Context
${PROJECT_CONTEXT_CONTENT}

---

# Your Role and Instructions
${INSTRUCTIONS}

---

# Your Task
The following payload triggered your execution:

\`\`\`json
${PAYLOAD}
\`\`\`

# Memory Layout
Your shared memory is at ${MEMORY_PATH}/
- ${MEMORY_PATH}/inbox/        — incoming requests (architect reads here)
- ${MEMORY_PATH}/specs/        — architect writes specs here
- ${MEMORY_PATH}/workspace/    — coder writes code here
- ${MEMORY_PATH}/reviews/      — reviewer writes reviews here
- ${MEMORY_PATH}/deployments/  — ops writes deployment logs here
- ${MEMORY_PATH}/queue/        — inter-agent signals (JSON files)
  - Write ${MEMORY_PATH}/queue/coder.json to trigger the Coder
  - Write ${MEMORY_PATH}/queue/tester.json to trigger the Tester
  - Write ${MEMORY_PATH}/queue/reviewer.json to trigger the Reviewer
  - Write ${MEMORY_PATH}/queue/ops.json to trigger Ops

# Important Rules
- Always write your output to the correct /memory/ directory
- When you are done, write the appropriate trigger file to /memory/queue/
- Write a brief log entry to ${MEMORY_PATH}/logs/${ROLE}-$(date -u +%Y%m%dT%H%M%S).md
- If you encounter an error, write it to ${MEMORY_PATH}/logs/${ROLE}-error-$(date -u +%Y%m%dT%H%M%S).md
- Never write secrets or API keys anywhere in /memory/

Begin your work now.
PROMPTEOF
)

# ── Run Claude Code ───────────────────────────────────────────────────────────

log "Launching Claude Code..."

# Write the prompt to a temp file (avoids shell escaping issues)
PROMPT_FILE=$(mktemp /tmp/agent-prompt-XXXXXX.md)
echo "$PROMPT" > "$PROMPT_FILE"

# Run Claude Code with:
#   --print          — non-interactive mode, prints response and exits
#   --max-turns 10   — limit agentic turns to prevent runaway loops
#   --no-cache       — fresh context each run
#   timeout          — kill if it exceeds AGENT_TIMEOUT seconds
EXIT_CODE=0

timeout "${AGENT_TIMEOUT}" claude \
  --print \
  --max-turns 10 \
  --dangerously-skip-permissions \
  "$(cat "$PROMPT_FILE")" 2>&1 | tee "${MEMORY_PATH}/logs/${ROLE}-output-$(date -u +%Y%m%dT%H%M%S).log" \
  || EXIT_CODE=$?

rm -f "$PROMPT_FILE"

# ── Handle completion ─────────────────────────────────────────────────────────

if [ $EXIT_CODE -eq 0 ]; then
  log "Completed successfully"
  # Clean up the trigger file we consumed
  if [ "$ROLE" != "architect" ] && [ -f "$PAYLOAD_FILE" ]; then
    rm -f "$PAYLOAD_FILE"
    log "Consumed trigger file: $PAYLOAD_FILE"
  fi
elif [ $EXIT_CODE -eq 124 ]; then
  die "Timed out after ${AGENT_TIMEOUT}s"
else
  die "Claude Code exited with code $EXIT_CODE"
fi

log "Agent $ROLE finished"
exit 0
