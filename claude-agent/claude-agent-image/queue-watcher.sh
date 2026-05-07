#!/bin/bash
# =============================================================================
# queue-watcher.sh
# Watches /memory/queue/ for new trigger files and POSTs to the dispatcher
# webhook to spawn the next agent in the pipeline.
#
# This runs as a sidecar container in the dispatcher pod, not in agent pods.
# It bridges the file-based signaling (/memory/queue/) with the
# webhook-based dispatching system.
#
# Flow:
#   Agent writes /memory/queue/coder.json
#     ↓
#   queue-watcher detects the new file
#     ↓
#   queue-watcher POSTs {"event": "architect.complete"} to dispatcher
#     ↓
#   dispatcher creates the Coder Job
# =============================================================================

set -euo pipefail

MEMORY_PATH="${MEMORY_PATH:-/memory}"
DISPATCHER_URL="${DISPATCHER_URL:-http://localhost:8080}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [queue-watcher] $*"
}

sign_payload() {
  local payload="$1"
  if [ -n "$WEBHOOK_SECRET" ]; then
    echo -n "$payload" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | cut -d' ' -f2
  fi
}

send_event() {
  local event_type="$1"
  local payload="$2"
  local sig
  sig=$(sign_payload "$payload")

  log "Sending event=$event_type"
  curl -s -X POST "$DISPATCHER_URL" \
    -H "Content-Type: application/json" \
    -H "X-Event-Type: $event_type" \
    ${sig:+-H "X-Hub-Signature-256: sha256=$sig"} \
    -d "$payload" \
    && log "Event dispatched: $event_type" \
    || log "WARNING: Failed to dispatch event: $event_type"
}

# Map queue filenames to event types
declare -A FILE_TO_EVENT=(
  ["coder.json"]="architect.complete"
  ["tester.json"]="coder.complete"
  ["reviewer.json"]="tester.complete"
  ["ops.json"]="reviewer.approved"
)

mkdir -p "${MEMORY_PATH}/queue"

log "Watching ${MEMORY_PATH}/queue/ every ${POLL_INTERVAL}s"

while true; do
  for queue_file in "${!FILE_TO_EVENT[@]}"; do
    full_path="${MEMORY_PATH}/queue/${queue_file}"
    if [ -f "$full_path" ]; then
      event="${FILE_TO_EVENT[$queue_file]}"
      payload=$(cat "$full_path")
      log "Found trigger file: $queue_file -> event: $event"

      # Add event type to payload
      enriched=$(echo "$payload" | jq --arg evt "$event" '. + {"event": $evt}' 2>/dev/null \
        || echo "{\"event\": \"$event\"}")

      send_event "$event" "$enriched"

      # Move processed file to archive so it doesn't retrigger
      mkdir -p "${MEMORY_PATH}/queue/processed"
      mv "$full_path" "${MEMORY_PATH}/queue/processed/${queue_file}-$(date -u +%Y%m%dT%H%M%S)"
      log "Archived trigger file: $queue_file"
    fi
  done

  sleep "$POLL_INTERVAL"
done
