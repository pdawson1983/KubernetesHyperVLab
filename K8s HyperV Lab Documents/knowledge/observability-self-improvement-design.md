# Observability → Self-Improvement Design

**Date:** 2026-05-10

## The Goal

The purpose of collecting observability data is not just operational visibility —
it is to give the `system.improve` loop the signal it needs to make AgentForge
better at its own job. The loop is:

```
Run pipeline → Collect structured data → Analyse inefficiencies
→ Propose changes to agent CLAUDE.md files → Test → Merge → Repeat
```

The "what to improve" signal comes from the data. Without it, the self-improvement
loop is just the architect guessing.

## What Data to Collect

Per pipeline run, per agent stage:

| Signal | Why it matters |
|--------|----------------|
| Turns used vs maxTurns | High turns on simple tasks → over-complicated instructions |
| Tool call sequence | Which tools agents reach for — reveals confusion or missing context |
| Token count (input + output) | Efficiency signal; bloated prompts waste turns |
| Time per stage | Slow stages may indicate unclear instructions or excessive tool use |
| Exit code + failure reason | Patterns in failure modes → targeted fixes |
| Output file sizes | Oversized specs/reviews may indicate agents writing noise |
| Queue file content | What context architect passes downstream — is it the right context? |
| Whether ops created a PR | Did the pipeline reach its intended outcome? |

## Where to Store It

Postgres in-cluster (single pod, NFS-backed PVC):
- One row per agent stage per run
- JSON column for free-form tool call log (Claude Code can write this)
- Queryable: `SELECT role, AVG(turns_used) FROM runs GROUP BY role`
- Same DB used by the web UI — deploy once, serve both purposes
- SQLite on NFS is a viable first step if Postgres feels heavy

## How Agents Contribute

Each agent writes a structured summary to its queue file and log. The ops agent
(or a new `observer` sidecar) reads the full chain and writes a single run record
to Postgres at pipeline completion.

The entrypoint log (`logs/<role>-entrypoint.log`) already captures exit codes and
Claude output tails. Adding turn count and tool call summary requires Claude Code
to write a brief structured block to its output log.

## The Self-Improvement Loop

1. `system.improve` event fires (manually or on a schedule)
2. Architect queries Postgres for the last N runs — identifies patterns:
   - Which stages fail most often
   - Which stages use the most turns
   - Which roles produce the least useful output
3. Architect reads the current `agent-base.md` and proposes targeted edits
4. Coder applies the edits to the repo
5. Tester runs the mock pipeline to verify the chain still works
6. Ops opens a PR — human reviews and merges
7. Next run uses the improved instructions

## What's Currently in Place

- `logs/<role>-entrypoint.log` — full startup trace on NFS (2026-05-10)
- `logs/<role>-output-<ts>.log` — full Claude Code output on NFS
- `task.json` — per-agent timing, exit_code, status
- `/memory/telemetry/<task-id>.json` — archived on completion/failure

## What's Missing

- Structured turn count / tool call summary per agent
- Postgres deployment and schema
- Observer that writes run records to DB at pipeline completion
- Self-improvement TRIGGER_MAP entry for `system.improve` event
- Query tooling (web UI or psql CLI) for exploring run history
