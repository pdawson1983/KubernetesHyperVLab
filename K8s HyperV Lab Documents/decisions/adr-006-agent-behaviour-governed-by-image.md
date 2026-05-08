# ADR: Agent Behaviour Governed by Image, Not Helm

**Date:** 2026-05-07
**Status:** accepted

## Context

Per-role agent instructions (Architect: "never write implementation code", Coder:
"never modify more than 10 files without a plan", etc.) were previously stored in
Helm `values.yaml` and injected into each agent pod as a ConfigMap mounted at
`/etc/agent/CLAUDE.md`. The dispatcher also injected a project context ConfigMap
at `/memory/CLAUDE.md` via a Helm-managed volume mount.

This created two problems:

1. **Orchestration layer controlled agent behaviour.** Changing how agents work
   required a `helm upgrade`, not a code change. The restrictions were arbitrary
   (set once during initial design) and prevented agents from adapting to the
   specific needs of the projects they were building.

2. **Bad practice.** Agent instructions lived outside the project being built.
   When an agent works on a real repo, that repo's own `CLAUDE.md` should govern
   conventions — not a Helm values file written by the pipeline operator.

## Decision

Remove all per-role instruction ConfigMaps and the Helm-injected project context
ConfigMap entirely. Replace with a three-tier model:

1. **`/agent/CLAUDE.md`** (image-baked, read automatically by Claude Code) — general
   pipeline operating rules: memory layout, chaining protocol, security rules, and
   a lightweight description of each role's purpose. Updated by editing
   `agent-base.md` and rebuilding the image. Human-controlled, version-controlled.

2. **`/memory/CLAUDE.md`** (optional, runtime) — shared task context written by the
   architect or user at the start of a run. Not injected by Helm; created by agents
   or operators as needed.

3. **`/memory/workspace/<project>/CLAUDE.md`** (project-owned) — written by the
   architect when starting work on a project. Contains project-specific conventions,
   tech stack, patterns. Read automatically by Claude Code when it navigates into
   the workspace. Agents own this; the orchestrator does not.

Helm now controls only infrastructure: image, resources, timeouts, token limits,
secret references, and routing. It does not control what agents think or how they work.

## Consequences

- **More capable agents.** Agents are no longer restricted by arbitrary rules baked
  into Helm config. They can adapt to the project they are building.
- **Projects own their conventions.** The architect writes project-specific CLAUDE.md
  into the workspace; downstream agents follow it. Different projects can have
  different conventions without any Helm changes.
- **Human control preserved.** Operators can still influence all agent behaviour by
  editing `agent-base.md` and rebuilding the image. This is the right abstraction:
  image controls policy, Helm controls infrastructure.
- **Behaviour changes require image rebuild.** Unlike the previous ConfigMap approach
  (change values.yaml → helm upgrade), changing general behaviour now requires:
  edit `agent-base.md` → `podman build --no-cache` → push → new pods pick it up.
- **Watch for:** if the architect does not write a workspace CLAUDE.md, downstream
  agents have no project-specific conventions and rely solely on the image-level
  instructions. This is acceptable — Claude Code applies good defaults.
