# ADR: Task-Scoped Memory Namespacing

**Date:** 2026-05-08
**Status:** proposed

## Context

All pipeline runs currently share a flat `/memory/` namespace:

```
/memory/inbox/          ← overwritten by next task
/memory/specs/          ← accumulates across all tasks
/memory/workspace/      ← accumulates across all tasks
/memory/reviews/        ← accumulates across all tasks
/memory/queue/          ← shared trigger files (conflict risk)
```

This causes two problems confirmed in testing:

1. **Accumulated content exhausts agent turns.** The reviewer, when asked to review a
   simple test task, reads all prior-run workspace content and exhausts its `--max-turns`
   limit (10 turns with Haiku) before completing its own task.

2. **Concurrent tasks would corrupt each other.** Two simultaneous `issue.opened` events
   would both write to `queue/coder.json`. The second write would overwrite the first,
   causing the wrong agent to receive the wrong payload.

Additionally, the current design has no concept of a "project" or "repository" — there
is no way for the architect to clone a specific repo and for all downstream agents to
work within that repo's context.

## Decision

Implement task-scoped memory namespacing. The dispatcher generates a unique task ID
(e.g., `YYYYMMDDTHHMMSS-<8-char-hex>`) when a webhook fires and includes it in the
inbox payload. All agents derive their working path from the task ID:

```
/memory/tasks/<task-id>/
├── inbox/              ← architect trigger (dispatcher writes here)
├── specs/              ← architect output
├── workspace/          ← coder output; optionally a git clone of the target repo
├── reviews/            ← reviewer output
├── deployments/        ← ops output
├── queue/              ← inter-agent triggers scoped to THIS task
│   └── active/
└── CLAUDE.md           ← task context (architect writes; all agents read)
```

The webhook payload is extended to include the repo URL and branch when provided:

```json
{
  "event": "issue.opened",
  "title": "Add login endpoint",
  "task_id": "20260508T154200-a3f92b1c",
  "repo": "git@github.com:yourorg/api-service.git",
  "branch": "main"
}
```

The entrypoint.sh reads `TASK_PATH` (derived from task_id) and all file operations
use `${TASK_PATH}/` instead of `/memory/`. The queue-watcher watches
`/memory/tasks/*/queue/` (glob) instead of the single flat `queue/`.

## Consequences

- **Concurrent tasks become safe.** Each task has its own queue, workspace, and specs.
  Multiple `issue.opened` events can fire simultaneously without conflict.
- **Workspace clutter eliminated.** Each task starts with an empty workspace. Agents
  only see files from the current task.
- **Multi-repo support.** The architect can `git clone <repo>` into `workspace/`, and
  the project's own `CLAUDE.md` governs conventions for that run.
- **Task history preserved.** Completed task directories persist in `/memory/tasks/`
  and can be inspected, archived, or cleaned up by TTL.
- **Breaking change for existing agents.** The `entrypoint.sh` and `agent-base.md`
  must be updated. The dispatcher and queue-watcher need changes. This is a
  significant refactor planned for the next session.
- **Watch for:** the queue-watcher glob pattern `/memory/tasks/*/queue/*.json` must
  not match `queue/active/` files (already-processed triggers). The move-to-active
  pattern from ADR-004 still applies within each task's queue directory.
