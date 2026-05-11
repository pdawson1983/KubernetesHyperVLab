# ADR-012: Postgres as Observability and Web UI Backend

**Date:** 2026-05-10
**Status:** accepted

## Context

AgentForge needed a queryable store for per-run data (timing, status, agent chain
outcomes) to feed the system self-improvement loop. Three options were evaluated:

1. **Loki + Grafana** — query pod logs by label/time; dashboards. No schema changes
   to agents. Read-only observability.
2. **Kafka** — event stream per agent event; fan-out to consumers; replayable. High
   operational weight for a 3-node lab cluster.
3. **Postgres** — structured schema; SQL queries; shared with web UI backend.

## Decision

Postgres. Single deployment in the `agentforge` namespace, backed by a 5Gi
local-path PVC. Schema: `pipeline_runs` (one row per task) + `agent_runs` (one row
per agent stage per task). Data is imported by the observer sidecar in the
dispatcher pod, which polls `/memory/telemetry/` every 30s for completed runs.

Loki+Grafana was specifically deferred — it provides read-only log observability but
not structured queryability. The self-improvement loop needs to aggregate across
runs (e.g. average turns per role, failure rate by agent) which is SQL, not log
search. Kafka was deferred as operationally heavy.

## Consequences

- **Easier:** Self-improvement loop can query `SELECT role, AVG(duration_seconds)
  FROM agent_runs GROUP BY role` without parsing log files.
- **Easier:** Web UI has a ready backend — no separate DB deployment needed.
- **Easier:** `pipeline_runs` + `agent_runs` are already populated from existing
  telemetry archives on startup.
- **Harder:** Postgres pod going down means no telemetry import until it recovers
  (observer retries indefinitely — data is not lost, just delayed).
- **Watch for:** The `postgres-credentials` secret must be recreated in every new
  namespace. The Postgres PVC has `resource-policy: keep` — data survives
  `helm uninstall` but not namespace deletion.
- **Phase 2:** Add turns_used + tool_call_sequence columns when agents write
  structured summaries (needed for self-improvement signal beyond timing).
