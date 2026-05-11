#!/usr/bin/env bash
# =============================================================================
# scripts/refresh-credentials.sh
# Checks Claude.ai Max credential expiry and syncs the K8s secret.
#
# Usage:
#   ./scripts/refresh-credentials.sh           # login only if expiring soon
#   ./scripts/refresh-credentials.sh --force   # always run claude auth login
#   ./scripts/refresh-credentials.sh --check   # print expiry and exit (no sync)
#
# Behaviour:
#   1. Read expiresAt from ~/.claude/.credentials.json
#   2. If expiring within WARN_THRESHOLD (default 2h) or already expired:
#      run 'claude auth login' interactively
#   3. Delete and recreate the claude-credentials K8s secret from the
#      (possibly refreshed) credentials file
#
# Scheduling (WSL — no persistent cron):
#   Add a Windows Task Scheduler entry to run every 20h:
#     Program: wsl.exe
#     Arguments: -e bash /mnt/c/Users/pdaws/OneDrive/Desktop/Lab/KubernetesHyperVLab/scripts/refresh-credentials.sh
# =============================================================================

set -euo pipefail

CREDS="${HOME}/.claude/.credentials.json"
NAMESPACE="agentforge"
SECRET_NAME="claude-credentials"
WARN_THRESHOLD=7200   # refresh if expiring within 2 hours (7200s)

log()  { echo "[$(date -u +%H:%M:%SZ)] $*"; }
die()  { log "ERROR: $*"; exit 1; }

MODE="${1:-}"

# ── Read expiry ───────────────────────────────────────────────────────────────

[ -f "$CREDS" ] || die "Credentials file not found: $CREDS — run 'claude auth login' first"

REMAINING=$(_CREDS="$CREDS" python3 - << 'PYEOF'
import json, time, os
try:
    c = json.load(open(os.environ['_CREDS']))
    exp_ms = c.get('claudeAiOauth', {}).get('expiresAt', 0)
    if not exp_ms:
        print(0)
    else:
        print(int(exp_ms / 1000 - time.time()))
except Exception:
    print(0)
PYEOF
)

expiry_display() {
    local s=$1
    if [ "$s" -lt 0 ]; then
        echo "EXPIRED ($(( -s / 60 ))m ago)"
    else
        echo "$(( s / 3600 ))h $(( (s % 3600) / 60 ))m"
    fi
}

# ── --check mode ──────────────────────────────────────────────────────────────

if [ "$MODE" = "--check" ]; then
    log "Credentials expire in: $(expiry_display "$REMAINING")"
    if [ "$REMAINING" -lt "$WARN_THRESHOLD" ]; then
        log "WARNING: below refresh threshold (${WARN_THRESHOLD}s) — run without --check to refresh"
        exit 1
    fi
    exit 0
fi

# ── Login if needed ───────────────────────────────────────────────────────────

NEEDS_LOGIN=false

if [ "$MODE" = "--force" ]; then
    log "Force login requested."
    NEEDS_LOGIN=true
elif [ "$REMAINING" -le 0 ]; then
    log "Credentials EXPIRED. Login required."
    NEEDS_LOGIN=true
elif [ "$REMAINING" -lt "$WARN_THRESHOLD" ]; then
    log "Credentials expiring in $(expiry_display "$REMAINING") — refreshing."
    NEEDS_LOGIN=true
else
    log "Credentials valid for $(expiry_display "$REMAINING") — skipping login."
fi

if [ "$NEEDS_LOGIN" = true ]; then
    log "Running: claude auth login"
    claude auth login
    log "Auth complete."
    # Re-read expiry after login
    REMAINING=$(_CREDS="$CREDS" python3 - << 'PYEOF'
import json, time, os
try:
    c = json.load(open(os.environ['_CREDS']))
    exp_ms = c.get('claudeAiOauth', {}).get('expiresAt', 0)
    print(int(exp_ms / 1000 - time.time()))
except Exception:
    print(0)
PYEOF
)
    log "New expiry: $(expiry_display "$REMAINING")"
fi

# ── Sync K8s secret ───────────────────────────────────────────────────────────

log "Syncing $SECRET_NAME secret in namespace $NAMESPACE..."
kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl create secret generic "$SECRET_NAME" \
    --from-file=.credentials.json="$CREDS" \
    -n "$NAMESPACE"
log "Secret synced. Agents will use refreshed credentials on next run."
log "Credentials valid for: $(expiry_display "$REMAINING")"
