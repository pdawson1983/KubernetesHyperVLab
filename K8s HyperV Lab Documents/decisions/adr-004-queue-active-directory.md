# ADR: queue/active/ staging directory for in-flight trigger files

**Date:** 2026-05-07
**Status:** accepted

## Context

The queue-watcher polls `/memory/queue/` every 5 seconds. When it detects a trigger file (e.g., `coder.json`), it fires the event to the dispatcher and immediately archived the file to `queue/processed/`. The dispatcher then creates the agent Job. However, by the time the pod was scheduled, pulled its image, and started, the trigger file was already gone — the agent exited immediately with "No trigger file found."

Root cause: archiving happened on dispatch (queue-watcher's schedule), not on consumption (agent's schedule). Pod startup latency (5–15s) exceeded the archive window.

## Decision

Queue-watcher moves trigger files to `queue/active/<role>.json` before dispatching the event instead of archiving to `queue/processed/`. `entrypoint.sh` checks `queue/<role>.json` first (direct write from previous agent), then falls back to `queue/active/<role>.json`. The agent deletes the file when it successfully completes, after which the queue-watcher (on its next pass) would archive anything left in `active/` as stale.

## Consequences

- **Easier:** Agent pods reliably find their trigger file regardless of scheduling latency.
- **Easier:** File lifecycle is clear: `queue/` → `queue/active/` → deleted by agent on success.
- **Watch for:** If an agent pod fails before deleting its `active/` file, the file stays indefinitely. A future cleanup job or queue-watcher housekeeping pass should archive stale `active/` files older than `AGENT_TIMEOUT`.
- **Watch for:** The dispatcher also writes to `queue/<role>.json` when it receives the chained event. In most cases the agent finds the dispatcher-written file directly (before the queue-watcher's next poll) and never needs the `active/` fallback. The fallback only activates if the queue-watcher polls again before the pod starts.
