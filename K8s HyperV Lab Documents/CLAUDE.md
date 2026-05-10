# K8s HyperV Lab Documents

This directory is the **persistent knowledge base** for this project — an Obsidian vault that survives local dev context, machine changes, and conversation resets.

When you learn something important during a session, document it here. When a decision is made, record it here. When a task is resolved, note the outcome here.

---

## Purpose

- **Decisions** — record *why* something was done, not just what. Future sessions won't remember context.
- **Knowledge** — hard-won operational knowledge (bugs fixed, workarounds found, configs that matter).
- **Tasks** — open work items that need to persist beyond a single session.
- **Runbooks** — step-by-step procedures for common operations.

---

## Document Index

| File | Contents |
|------|----------|
| `k8s-hyperv-guide.md` | Full cluster setup guide: Hyper-V, Ubuntu VMs, kubeadm, Flannel, MetalLB, NFS, local-path |
| `decisions/` | Architecture Decision Records (ADRs) — one file per decision |
| `diagrams/` | Mermaid diagrams: cluster topology, agent flow, MCP pattern, WSL connectivity |
| `runbooks/` | Step-by-step operational procedures |
| `tasks.md` | Open tasks and backlog (persistent across sessions) |

---

## When to Add a Document

| Situation | What to write |
|-----------|---------------|
| A bug took >30 min to diagnose | Add a `knowledge/` note with symptoms, cause, fix |
| A design choice was made | Add an ADR in `decisions/` |
| A procedure was worked out manually | Add a runbook in `runbooks/` |
| A new open task is identified | Add to `tasks.md` |
| A task is completed | Update `tasks.md` with outcome and date |

---

## ADR Format (`decisions/<slug>.md`)

```markdown
# ADR: <title>

**Date:** YYYY-MM-DD
**Status:** accepted | superseded | deprecated

## Context
What problem or constraint prompted this decision.

## Decision
What was decided.

## Consequences
What becomes easier, what becomes harder, what to watch for.
```

---

## Cluster Quick Reference

| Node | IP | Role |
|------|----|------|
| k8s-control | 192.168.100.10 | Control plane + NFS server |
| k8s-worker1 | 192.168.100.11 | Worker (registry NodePort :30500) |
| k8s-worker2 | 192.168.100.12 | Worker |

- MetalLB / nginx-ingress LB IP: `192.168.100.200`
- WSL route (re-add after restart): `sudo ip route add 192.168.100.0/24 via 172.24.240.1`
- `/etc/hosts` (WSL + Windows): `192.168.100.200 webhook.k8s.local`
