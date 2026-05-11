# ADR-014: Task-Scoped CLAUDE.md Written from Submit Form Context Field

**Date:** 2026-05-11
**Status:** accepted

## Context

Agents currently receive context only through the payload JSON (title, repoUrl,
event type) and the global `/memory/CLAUDE.md` shared across all tasks. Users
needed a way to provide rich per-task instructions — constraints, acceptance
criteria, tech preferences — that all five agents would see, not just the
architect's initial prompt.

Two approaches were considered:

1. **Embed context in the prompt only** — include the description field in the
   architect's prompt text. Downstream agents (coder, tester, reviewer, ops)
   would only see it if the architect chose to echo it into queue files.

2. **Write as task-scoped CLAUDE.md** — dispatcher writes the context field to
   `/memory/tasks/<task-id>/CLAUDE.md`. Every agent reads it via
   `entrypoint.sh` before invoking Claude Code, independent of what the
   architect passes downstream.

## Decision

Option 2. The dispatcher writes the `context` payload field to
`/memory/tasks/<task-id>/CLAUDE.md` when present. `entrypoint.sh` checks the
task-scoped path first, then falls back to the global `/memory/CLAUDE.md`.

This gives all five agents equal access to user-provided instructions without
relying on the architect to propagate them. It also mirrors how the architect
itself would write a task-scoped CLAUDE.md for downstream agents, making the
submit form a first-class alternative to the architect step for project
configuration.

## Consequences

- **Easier:** Users can specify constraints that every agent enforces — coder
  won't choose the wrong language, tester won't install banned libraries, ops
  won't create the wrong PR format.
- **Easier:** The context field is a natural place for future wizard-generated
  CLAUDE.md content (ADR candidate when the wizard is built).
- **Harder:** If both a task-scoped and global CLAUDE.md exist, the task-scoped
  one silently wins. Users who set a global CLAUDE.md and don't realise this
  could be confused.
- **Watch for:** The architect may also write its own CLAUDE.md to the workspace
  subdirectory (`workspace/<project>/CLAUDE.md`). The task-level CLAUDE.md
  covers all agents; the workspace CLAUDE.md is project-specific conventions.
  These are additive — entrypoint.sh reads the task-level one into the prompt;
  Claude Code auto-reads the workspace one from WORKDIR if present.
