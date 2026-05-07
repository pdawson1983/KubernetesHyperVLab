# ADR: Dispatcher Must Not Write to queue/ for Non-Architect Agents

**Date:** 2026-05-07
**Status:** accepted

## Context

**CRITICAL — this caused a runaway loop that spawned hundreds of jobs.**

The dispatcher originally wrote `queue/<agent>.json` for every agent it created, including non-architect agents (coder, tester, reviewer, ops). The queue-watcher watches `queue/` for these exact filenames and fires events when it finds them. This created an infinite loop:

1. Architect writes `queue/coder.json`
2. Queue-watcher moves to `queue/active/coder.json`, fires `architect.complete`
3. Dispatcher receives `architect.complete` → writes `queue/coder.json` (NEW file)
4. Queue-watcher polls again, finds new `queue/coder.json` → fires `architect.complete` again
5. Dispatcher creates another coder job and writes `queue/coder.json` again
6. → infinite loop spawning jobs every 5 seconds

The cluster accumulated 100+ pending pods across coder/tester/reviewer/ops before being stopped by scaling dispatcher to 0.

## Decision

The dispatcher only writes to `memory/inbox/` for the architect agent (external entry point with no prior trigger file). For all other agents, the trigger file was already written by the **previous agent** (via Claude Code) and moved to `queue/active/` by the queue-watcher. The dispatcher must only create the Job — it must NOT write any file to `queue/`.

## Consequences

- **Loop eliminated.** The queue-watcher will never see a dispatcher-written trigger file.
- **Agent input:** Non-architect agents read their trigger from `queue/active/<role>.json` (moved there by queue-watcher) or `queue/<role>.json` (if the agent completes and the queue-watcher hasn't polled yet — normal case).
- **Watch for:** If an agent fails to write its downstream trigger file (e.g., coder fails before writing `tester.json`), the pipeline silently stops. No error propagation mechanism exists yet.
- **Watch for:** The `queue/active/` cleanup on agent failure needs attention — see ADR-004.
