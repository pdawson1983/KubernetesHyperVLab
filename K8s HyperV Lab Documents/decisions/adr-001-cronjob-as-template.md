# ADR: CronJob-as-Template Pattern for Agent Jobs

**Date:** 2026-05-07
**Status:** accepted

## Context

Agent runs need to be triggered on-demand by external events (webhook, queue file). Each run should be a clean, isolated pod. Options considered:
- Kubernetes Job created from a raw manifest (requires storing/templating the full spec externally)
- Deployment with a trigger sidecar (wrong lifecycle — Deployments stay running)
- CronJob with `kubectl create job --from cronjob/` (reuses pod spec, creates clean instances)

## Decision

Use suspended CronJobs (`suspend: true`, `schedule: "0 0 31 2 *"`) as permanent pod spec templates. The dispatcher runs `kubectl create job --from=cronjob/<name>` to spawn instances on demand.

## Consequences

- **Easier:** Pod spec lives in one place (the CronJob template). No external manifest management.
- **Easier:** `helm upgrade` updates the template; next spawned job gets the new spec automatically.
- **Harder:** The pattern is non-obvious — "why is a CronJob that never fires in this chart?" needs explanation for newcomers.
- **Watch for:** `kubectl create job --from cronjob/` does not support overriding env vars per-invocation. If per-run parameterization is needed, switch to a Job factory (e.g., Tekton TaskRun or a custom controller).
