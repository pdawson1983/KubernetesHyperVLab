#!/bin/bash
# =============================================================================
# entrypoint.sh
# Main agent entrypoint. Runs inside every agent container.
#
# Flow:
#   1. Validate AGENT_ROLE, TASK_ID, and auth (API key or Claude.ai credentials)
#   2. Set MEMORY_BASE = /memory/tasks/$TASK_ID (task-scoped subdirectory)
#   3. Record agent start time in task.json
#   4. Find the trigger payload (inbox for architect, queue for others)
#   5. Build a prompt: role identity + task memory base + payload + project context
#   6. Run Claude Code — it reads /agent/CLAUDE.md automatically from WORKDIR
#   7. Record agent completion in task.json; archive to /memory/telemetry/ when done
#
# Role-specific behaviour and project conventions come from:
#   /agent/CLAUDE.md          — baked into image, read automatically by Claude Code
#   /memory/CLAUDE.md         — written by architect or user, included in prompt if present
#   /memory/tasks/$TASK_ID/workspace/<proj>/CLAUDE.md — project conventions
# =============================================================================

set -euo pipefail

# ── Early environment — needed before log() can reference them ────────────────

AGENT_ROLE="${AGENT_ROLE:-}"
TASK_ID="${TASK_ID:-}"
MEMORY_PATH="${MEMORY_PATH:-/memory}"
MEMORY_BASE="${MEMORY_PATH}/tasks/${TASK_ID}"

# ── Persistent entrypoint log ─────────────────────────────────────────────────
# Written to NFS alongside Claude output so the full agent trace survives pod
# termination. Created before validation so even startup errors are captured.

_LOG_DIR="${MEMORY_BASE}/logs"
_LOG_FILE="${_LOG_DIR}/${AGENT_ROLE:-agent}-entrypoint.log"
mkdir -p "$_LOG_DIR" 2>/dev/null || true

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_ROLE:-agent}] $*"
  echo "$msg"
  echo "$msg" >> "$_LOG_FILE" 2>/dev/null || true
}

die() {
  log "ERROR: $*"
  exit 1
}

# ── Validate environment ──────────────────────────────────────────────────────

[ -z "${AGENT_ROLE}" ] && die "AGENT_ROLE is not set"
[ -z "${TASK_ID}" ]    && die "TASK_ID is not set"

AGENT_TIMEOUT="${AGENT_TIMEOUT:-300}"
AGENT_MAX_TURNS="${AGENT_MAX_TURNS:-10}"

log "Starting agent role=$AGENT_ROLE task=$TASK_ID timeout=${AGENT_TIMEOUT}s max-turns=${AGENT_MAX_TURNS}"

# ── Auth: API key or Claude.ai credentials ───────────────────────────────────

CREDS_MOUNT="${HOME:-/home/agent}/.claude-creds/.credentials.json"
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  if [ -f "$CREDS_MOUNT" ]; then
    mkdir -p "${HOME:-/home/agent}/.claude"
    cp "$CREDS_MOUNT" "${HOME:-/home/agent}/.claude/.credentials.json"
    log "Using Claude.ai credentials from mounted secret"
  else
    die "Neither ANTHROPIC_API_KEY nor claude-credentials secret is configured"
  fi
fi

# ── Ensure task-scoped memory directories exist ───────────────────────────────

mkdir -p \
  "${MEMORY_BASE}/inbox" \
  "${MEMORY_BASE}/specs" \
  "${MEMORY_BASE}/queue" \
  "${MEMORY_BASE}/queue/active" \
  "${MEMORY_BASE}/workspace" \
  "${MEMORY_BASE}/reviews" \
  "${MEMORY_BASE}/deployments" \
  "${MEMORY_BASE}/logs"

# ── Telemetry: record agent start ─────────────────────────────────────────────

_START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_START_EPOCH=$(date +%s)

python3 -c "
import json, pathlib
p = pathlib.Path('${MEMORY_BASE}/task.json')
if p.exists():
    d = json.loads(p.read_text())
    d.setdefault('agents', {})['${AGENT_ROLE}'] = {'started_at': '${_START_TS}', 'status': 'running'}
    p.write_text(json.dumps(d, indent=2))
" 2>/dev/null || true

# ── Telemetry: record agent completion and archive if final ───────────────────
# Call with: _record_completion <agent_status> [exit_code]

_record_completion() {
  local agent_status="$1"
  local exit_code="${2:-0}"
  local end_ts end_dur
  end_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  end_dur=$(( $(date +%s) - _START_EPOCH ))

  python3 -c "
import json, pathlib, shutil
from datetime import datetime, timezone

p = pathlib.Path('${MEMORY_BASE}/task.json')
if not p.exists():
    exit(0)
d = json.loads(p.read_text())

entry = d.setdefault('agents', {}).setdefault('${AGENT_ROLE}', {})
entry.update({
    'completed_at': '$end_ts',
    'duration_seconds': $end_dur,
    'status': '$agent_status',
    'exit_code': $exit_code,
    'log': 'logs/${AGENT_ROLE}-entrypoint.log',
})

is_final = '${AGENT_ROLE}' == 'ops' or '$agent_status' != 'success'
if is_final:
    task_status = 'completed' if '$agent_status' == 'success' else 'failed'
    d['status'] = task_status
    d['completed_at'] = '$end_ts'
    if '$agent_status' != 'success':
        d['failed_agent'] = '${AGENT_ROLE}'
    try:
        c = datetime.fromisoformat(d.get('created_at', '$end_ts').replace('Z', '+00:00'))
        e = datetime.fromisoformat('$end_ts'.replace('Z', '+00:00'))
        d['duration_seconds'] = int((e - c).total_seconds())
    except Exception:
        pass
    p.write_text(json.dumps(d, indent=2))
    tel = pathlib.Path('${MEMORY_PATH}/telemetry')
    tel.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(p), str(tel / (d.get('task_id', '${TASK_ID}') + '.json')))
else:
    p.write_text(json.dumps(d, indent=2))
" 2>/dev/null || true
}

# ── Find the trigger payload ──────────────────────────────────────────────────

PAYLOAD_FILE=""

if [ "$AGENT_ROLE" = "architect" ]; then
  PAYLOAD_FILE=$(ls -t "${MEMORY_BASE}/inbox/"*.json 2>/dev/null | head -1 || true)
  [ -z "$PAYLOAD_FILE" ] && die "No payload found in ${MEMORY_BASE}/inbox/"
else
  PAYLOAD_FILE="${MEMORY_BASE}/queue/${AGENT_ROLE}.json"
  if [ ! -f "$PAYLOAD_FILE" ]; then
    PAYLOAD_FILE="${MEMORY_BASE}/queue/active/${AGENT_ROLE}.json"
    [ -f "$PAYLOAD_FILE" ] || die "No trigger file found at queue/${AGENT_ROLE}.json or queue/active/${AGENT_ROLE}.json"
    log "Reading trigger from active/: $PAYLOAD_FILE"
  fi
fi

log "Reading payload from: $PAYLOAD_FILE"
PAYLOAD=$(cat "$PAYLOAD_FILE")

# ── Mock mode ─────────────────────────────────────────────────────────────────

if [ "${AGENT_MOCK:-false}" = "true" ]; then
  log "MOCK MODE — writing fixture output, skipping Claude"
  TS=$(date -u +%Y%m%dT%H%M%S)
  TASK=$(echo "$PAYLOAD" | jq -r '.title // .event // "mock task"' 2>/dev/null || echo "mock task")

  case "$AGENT_ROLE" in
    architect)
      cat > "${MEMORY_BASE}/specs/mock-spec-${TS}.md" << EOF
# Mock Spec: ${TASK}
Generated by architect (mock) at ${TS}.

## Component: mock-service
- Endpoint: GET /mock → {"status":"ok"}
- Implementation: single Python file
EOF
      printf '{"from":"architect","task":"%s","output":"%s/specs/mock-spec-%s.md","notes":"mock run"}\n' \
        "$TASK" "$MEMORY_BASE" "$TS" > "${MEMORY_BASE}/queue/coder.json"
      ;;
    coder)
      mkdir -p "${MEMORY_BASE}/workspace/mock-project"
      cat > "${MEMORY_BASE}/workspace/mock-project/main.py" << 'EOF'
def hello():
    return {"status": "ok"}
EOF
      printf '{"from":"coder","task":"mock implementation","output":"%s/workspace/mock-project","notes":"mock run"}\n' \
        "$MEMORY_BASE" > "${MEMORY_BASE}/queue/tester.json"
      ;;
    tester)
      mkdir -p "${MEMORY_BASE}/workspace/mock-project"
      cat > "${MEMORY_BASE}/workspace/mock-project/test_main.py" << 'EOF'
from main import hello

def test_hello():
    assert hello() == {"status": "ok"}
EOF
      printf '{"from":"tester","task":"mock tests","output":"%s/workspace/mock-project/test_main.py","notes":"mock run"}\n' \
        "$MEMORY_BASE" > "${MEMORY_BASE}/queue/reviewer.json"
      ;;
    reviewer)
      cat > "${MEMORY_BASE}/reviews/mock-review-${TS}.md" << EOF
# Mock Review — ${TS}
Status: APPROVED
No issues found. Smoke test passed review stage.
EOF
      printf '{"from":"reviewer","task":"mock review","output":"%s/reviews/mock-review-%s.md","notes":"mock run — approved"}\n' \
        "$MEMORY_BASE" "$TS" > "${MEMORY_BASE}/queue/ops.json"
      ;;
    ops)
      mkdir -p "${MEMORY_BASE}/deployments/mock-${TS}"
      cat > "${MEMORY_BASE}/deployments/mock-${TS}/deployment.md" << EOF
# Mock Deployment — ${TS}
Status: SUCCESS
Full pipeline smoke test completed at ${TS}.
Chain: architect → coder → tester → reviewer → ops — all succeeded.
EOF
      ;;
    *)
      log "Unknown role in mock mode: $AGENT_ROLE — no fixture written"
      ;;
  esac

  cat > "${MEMORY_BASE}/logs/${AGENT_ROLE}-mock-${TS}.md" << EOF
# ${AGENT_ROLE} mock run — ${TS}
Task: ${TASK}
Result: Fixture written, trigger sent (if applicable).
EOF

  if [ "$AGENT_ROLE" != "architect" ] && [ -f "$PAYLOAD_FILE" ]; then
    rm -f "$PAYLOAD_FILE" 2>/dev/null \
      && log "Consumed trigger file: $PAYLOAD_FILE" \
      || log "Warning: could not remove trigger file $PAYLOAD_FILE (non-fatal)"
  fi

  _record_completion "success" 0
  log "Mock run complete"
  exit 0
fi

# ── Configure MCP servers ─────────────────────────────────────────────────────

MCP_SERVERS=$(python3 -c "
import json, sys
try:
    with open('${PAYLOAD_FILE}') as f:
        d = json.load(f)
    json.dump(d.get('mcpServers', []), sys.stdout)
except Exception:
    sys.stdout.write('[]')
")

if [ "$MCP_SERVERS" != "[]" ] && [ -n "$MCP_SERVERS" ]; then
  log "Configuring MCP servers: $MCP_SERVERS"
  _MCP_SERVERS="$MCP_SERVERS" python3 << 'PYEOF'
import json, os

servers = json.loads(os.environ['_MCP_SERVERS'])
url_map = {
    'github': os.environ.get('MCP_GITHUB_URL', ''),
}
mcp_config = {}
for name in servers:
    url = url_map.get(name, '')
    if url:
        mcp_config[name] = {'type': 'http', 'url': url}
    else:
        print('[entrypoint] Warning: MCP server "' + name + '" requested but MCP_' + name.upper() + '_URL not set', flush=True)
if mcp_config:
    settings_path = os.path.join(os.environ.get('HOME', '/home/agent'), '.claude', 'settings.json')
    existing = {}
    try:
        with open(settings_path) as f:
            existing = json.load(f)
    except Exception:
        pass
    existing['mcpServers'] = mcp_config
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    with open(settings_path, 'w') as f:
        json.dump(existing, f, indent=2)
    print('[entrypoint] MCP configured: ' + str(list(mcp_config.keys())), flush=True)
    print('[entrypoint] settings.json: ' + json.dumps(existing), flush=True)
PYEOF
fi

# ── Configure git for GitHub ──────────────────────────────────────────────────

if [ -n "${GITHUB_TOKEN:-}" ]; then
  git config --global \
    "url.https://x-access-token:${GITHUB_TOKEN}@github.com/.insteadOf" \
    "https://github.com/"
  git config --global user.email "agentforge@cluster.local"
  git config --global user.name "AgentForge"
  log "Git configured for GitHub authentication"
fi

# ── Build the prompt ──────────────────────────────────────────────────────────

PROJECT_CONTEXT_CONTENT=""
if [ -f "${MEMORY_BASE}/CLAUDE.md" ]; then
  PROJECT_CONTEXT_CONTENT=$(cat "${MEMORY_BASE}/CLAUDE.md")
  log "Including task context from ${MEMORY_BASE}/CLAUDE.md"
elif [ -f "${MEMORY_PATH}/CLAUDE.md" ]; then
  PROJECT_CONTEXT_CONTENT=$(cat "${MEMORY_PATH}/CLAUDE.md")
  log "Including global context from ${MEMORY_PATH}/CLAUDE.md"
fi

PROMPT=$(cat << PROMPTEOF
# Your Role
You are the **${AGENT_ROLE}** agent.

# Task Memory Base
Your task-scoped memory directory is: **${MEMORY_BASE}**
Use this as the root for all reads and writes in this pipeline run.
Do not use flat /memory/ paths — this run is isolated under its own task subdirectory.

# Your Task
The following payload triggered your execution:

\`\`\`json
${PAYLOAD}
\`\`\`
${PROJECT_CONTEXT_CONTENT:+
# Project Context
${PROJECT_CONTEXT_CONTENT}
}
Begin your work now.
PROMPTEOF
)

# ── Run Claude Code ───────────────────────────────────────────────────────────

log "Launching Claude Code..."

CLAUDE_OUTPUT_LOG="${MEMORY_BASE}/logs/${AGENT_ROLE}-output-$(date -u +%Y%m%dT%H%M%S).log"
PROMPT_FILE=$(mktemp /tmp/agent-prompt-XXXXXX.md)
echo "$PROMPT" > "$PROMPT_FILE"

EXIT_CODE=0
timeout "${AGENT_TIMEOUT}" claude \
  --print \
  --max-turns "${AGENT_MAX_TURNS}" \
  --dangerously-skip-permissions \
  "$(cat "$PROMPT_FILE")" 2>&1 | tee "$CLAUDE_OUTPUT_LOG" \
  || EXIT_CODE=$?

rm -f "$PROMPT_FILE"

log "Claude Code exited with code $EXIT_CODE"

# On non-zero exit, copy last 30 lines of Claude output into the entrypoint log
# so it's visible even after the pod is gone.
if [ $EXIT_CODE -ne 0 ]; then
  log "--- last 30 lines of Claude output ---"
  tail -30 "$CLAUDE_OUTPUT_LOG" >> "$_LOG_FILE" 2>/dev/null || true
  log "--- end of Claude output ---"
fi

# ── Handle completion ─────────────────────────────────────────────────────────

if [ $EXIT_CODE -eq 0 ]; then
  _record_completion "success" 0
  log "Completed successfully"
  if [ "$AGENT_ROLE" != "architect" ] && [ -f "$PAYLOAD_FILE" ]; then
    rm -f "$PAYLOAD_FILE" 2>/dev/null \
      && log "Consumed trigger file: $PAYLOAD_FILE" \
      || log "Warning: could not remove trigger file $PAYLOAD_FILE (NFS ownership — non-fatal)"
  fi
elif [ $EXIT_CODE -eq 124 ]; then
  _record_completion "timeout" 124
  die "Timed out after ${AGENT_TIMEOUT}s"
else
  _record_completion "failed" "$EXIT_CODE"
  die "Claude Code exited with code $EXIT_CODE"
fi

log "Agent $AGENT_ROLE finished"
exit 0
