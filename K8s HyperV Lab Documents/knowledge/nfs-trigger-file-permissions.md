# NFS Trigger File Ownership Causes Pod False-Error

**Date:** 2026-05-08

## Symptoms

Agent pods (coder, tester, reviewer, ops) show `Error` status in `kubectl get pods`
even though their logs show `Completed successfully` and all work was done correctly.
The last log line is:

```
rm: cannot remove '/memory/queue/active/<role>.json': Permission denied
```

The pod exits non-zero, Kubernetes marks it as Failed/Error, and the `backoffLimit`
may trigger unnecessary retries.

## Root Cause

The queue-watcher sidecar runs inside the dispatcher pod. It moves trigger files from
`/memory/queue/<role>.json` to `/memory/queue/active/<role>.json` before firing the
event to the dispatcher. The queue-watcher process runs as whatever UID the dispatcher
container uses (typically root or the node's default).

Agent pods run as UID 1001 (`agent` user). When `entrypoint.sh` tries to clean up the
trigger file it consumed (`rm -f /memory/queue/active/<role>.json`), it hits a
Permission denied error because the file is owned by a different UID on the NFS volume.

With `set -euo pipefail` in the entrypoint, this non-zero `rm` exit causes the entire
script to exit non-zero after the work is already complete.

## Fix

Made the trigger file cleanup non-fatal in `entrypoint.sh`:

```bash
# Before (causes pod Error on permission denied):
rm -f "$PAYLOAD_FILE"
log "Consumed trigger file: $PAYLOAD_FILE"

# After (non-fatal — logs warning, pod exits 0):
rm -f "$PAYLOAD_FILE" 2>/dev/null \
  && log "Consumed trigger file: $PAYLOAD_FILE" \
  || log "Warning: could not remove trigger file $PAYLOAD_FILE (NFS ownership — non-fatal)"
```

The trigger file remaining in `queue/active/` is harmless — the queue-watcher only
watches `queue/` (not `queue/active/`), so stale files there do not trigger re-firing.

## Prevention

- The proper long-term fix is to set consistent UID ownership on the NFS volume, either
  by running the queue-watcher as UID 1001, or by setting `fsGroup: 1001` on the
  dispatcher pod's `securityContext` so files it creates are group-owned by 1001.
- Add `securityContext.runAsUser: 1001` to the dispatcher deployment to align file
  ownership. This requires verifying the queue-watcher script runs correctly as non-root.
- If stale `queue/active/` files accumulate (e.g., after pod failures), clean them manually:
  ```bash
  kubectl exec -n agentforge \
    $(kubectl get pod -n agentforge -l app.kubernetes.io/name=webhook-dispatcher -o name | head -1) \
    -c dispatcher -- sh -c 'rm -f /memory/queue/active/*.json'
  ```
