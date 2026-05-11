# ADR-013: AgentForge Naming Convention for K8s Resources

**Date:** 2026-05-10
**Status:** accepted

## Context

All Kubernetes resources were named `claude-agents-claude-agents-*` because the
Helm release name (`claude-agents`) and chart name (`claude-agents`) were
concatenated by the default `fullname` helper. Pod names were unreadable
at a glance and didn't reflect the system name (AgentForge).

Three options were considered:

1. **Rename the Helm release** — `helm uninstall` + `helm install agentforge`.
   Release name would be `agentforge` but resources still follow chart naming.
2. **Rename the chart** — change `name: claude-agents` in `Chart.yaml` to
   `agentforge`. Breaking change; archive/upgrade path becomes complex.
3. **`fullnameOverride` in values.yaml** — standard Helm pattern; overrides
   the generated fullname for all resources without touching chart internals.

## Decision

Use `fullnameOverride: agentforge` in `values.yaml`, combined with the standard
Helm contains-based deduplication in the `fullname` helper (when release name
contains chart name, use release name directly). This gives `agentforge-*`
resource names regardless of release name.

Also migrated namespace from `claude-agents` to `agentforge` for full
consistency. The Helm release name remains `claude-agents` internally.

The `RESOURCE_PREFIX` env var (= `{{ include "claude-agents.fullname" . }}`) is
injected into the dispatcher so CronJob references always use the correct prefix,
independent of the Helm release name.

## Consequences

- **Easier:** `kubectl get pods -n agentforge` shows `agentforge-webhook`,
  `agentforge-architect`, etc. — immediately readable.
- **Easier:** Adding a new MCP server just inherits `agentforge-<server>` naming
  automatically via the `fullname` helper.
- **Harder:** Renaming resources requires deleting old K8s resources manually
  before the upgrade (NodePort and Ingress conflicts prevent in-place rename).
- **Harder:** `registry-tls` and other secrets must be recreated in the new
  namespace — they are not git-tracked.
- **Watch for:** If `fullnameOverride` is ever removed, all resources revert to
  `claude-agents-*` naming and require the same delete-and-upgrade migration.
- **Future:** To rename the Helm release to `agentforge`, `helm uninstall` +
  `helm install agentforge . -n agentforge` — PVCs with `resource-policy: keep`
  survive; secrets must be recreated.
