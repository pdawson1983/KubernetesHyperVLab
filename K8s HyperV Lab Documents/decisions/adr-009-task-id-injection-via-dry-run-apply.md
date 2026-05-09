# ADR: Task ID Injection via kubectl dry-run + apply

**Date:** 2026-05-09
**Status:** accepted

## Context

Task-scoped memory required every agent Job to know its `TASK_ID` as an environment
variable. Agent CronJob templates are static Helm resources — they cannot be parameterised
at runtime with a per-invocation value.

Two alternatives were considered:

1. **`kubectl create job --from --overrides`** — the `--overrides` flag applies a JSON
   merge patch. A merge patch on an array (like `env`) replaces the entire array rather
   than appending. This would wipe all existing env vars (AGENT_ROLE, AGENT_MOCK, etc.)
   unless the full array was reconstructed in the overrides JSON — fragile and
   maintenance-heavy.

2. **`kubectl create job --from --dry-run=client -o json` → inject → `kubectl apply -f -`**
   — generates the full Job manifest in memory, appends `TASK_ID` to each container's
   `env` list in Python, then applies the modified JSON. Preserves all existing env vars.

## Decision

Use the dry-run + apply pattern (option 2). The dispatcher Python function
`create_agent_job(job_name, source_cronjob, namespace, task_id)`:
1. Calls `kubectl create job --from cronjob/<name> --dry-run=client -o json`
2. Parses the JSON and appends `{"name": "TASK_ID", "value": task_id}` to all containers
   and init containers
3. Calls `kubectl apply -f -` with the modified JSON on stdin

## Consequences

- **Easier:** TASK_ID is reliably present in every agent pod regardless of how many
  env vars the CronJob template defines. Adding new CronJob env vars requires no change
  to the dispatcher.
- **Harder:** Job creation is now two kubectl calls instead of one. Both calls must
  succeed for a job to be created. The dispatcher wraps both in try/except and returns
  500 on failure.
- **Watch for:** `kubectl apply` on a Job that already exists will fail (Jobs are
  immutable once created). The random hex suffix in job names prevents collisions in
  practice; this is acceptable for a lab.
