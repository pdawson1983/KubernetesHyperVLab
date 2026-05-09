# Task-Scoped NFS Directory Permissions: Dispatcher Root vs Agent UID 1001

**Date:** 2026-05-09

## Symptoms

Agent pods fail immediately after starting with:
```
mkdir: cannot create directory '/memory/tasks/<task-id>/specs': Permission denied
mkdir: cannot create directory '/memory/tasks/<task-id>/queue': Permission denied
```
The task directory itself exists (created by the dispatcher) but the agent cannot
create subdirectories inside it.

## Root Cause

The dispatcher runs in a `python:3.12-slim` container as root (UID 0). Agent pods run
as UID 1001 (the `agent` user baked into the Dockerfile).

When the dispatcher creates `/memory/tasks/<task-id>/` on the NFS volume, the directory
is owned by root with mode 755 (drwxr-xr-x). UID 1001 has read + execute on the
directory but not write, so `mkdir` from the agent fails.

## Fix

In the dispatcher Python, after creating the task base directory and inbox, apply
`os.chmod(task_base, 0o777)` and `os.chmod(inbox_dir, 0o777)`:

```python
task_base = MEMORY_PATH / "tasks" / task_id
target_dir = task_base / "inbox"
target_dir.mkdir(parents=True, exist_ok=True)
os.chmod(str(task_base), 0o777)   # allow agent (UID 1001) to create subdirs
os.chmod(str(target_dir), 0o777)  # allow agent to write inbox files
```

The agent's `entrypoint.sh` then runs `mkdir -p $MEMORY_BASE/{specs,queue,...}` which
succeeds because the parent is now world-writable.

## Prevention

Any time the dispatcher (root) pre-creates directories that agent pods (UID 1001) need
to write into, apply `os.chmod(..., 0o777)` immediately after creation. The longer-term
fix is `securityContext: runAsUser: 1001` on the dispatcher pod — this would eliminate
the UID mismatch entirely. That item remains in the backlog.
