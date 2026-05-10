# ADR-011: MCP as the Extensibility Pattern for Agent Capabilities

**Date:** 2026-05-09
**Status:** accepted

## Context

The pipeline agents (Architect, Coder, Reviewer, Tester, Ops) need to interact
with external systems: GitHub (clone, push, open PRs), future databases, APIs,
registries, and tooling. Two approaches were considered:

1. **Bake tools into the image** — install `git`, `gh`, `kubectl`, etc. in the
   Dockerfile. Simple upfront, but every new integration requires an image rebuild
   and push. Agent capabilities are static per image tag.

2. **MCP (Model Context Protocol) servers** — run capability servers as in-cluster
   deployments; agents connect at runtime via Claude Code's MCP support. New
   integrations are added by deploying a new MCP server and updating
   `agent-base.md` or per-task `CLAUDE.md` — no image rebuild required.

The immediate trigger was git repo integration (coder clones a repo, pushes a
branch; ops opens a PR). The `git` + `gh` approach works for that one case but
doesn't scale — each new external system adds more baked-in tooling.

## Decision

MCP is the standard extensibility pattern for adding new capabilities to agents.

- **In-cluster MCP servers** run as Kubernetes Deployments in the `claude-agents`
  namespace, exposed via ClusterIP Services.
- **Claude Code MCP config** is set in `agent-base.md` (baked into image) for
  capabilities all agents share, or in the per-task `/memory/CLAUDE.md` for
  task-specific integrations.
- **Image tooling** is kept minimal — only what is truly universal (node, claude
  CLI, basic shell). External system interaction goes through MCP.
- **GitHub MCP server** (`ghcr.io/github/github-mcp-server`) is the first
  implementation, covering: repo clone/push, PR creation, issue reading, repo create.
- **MCP server deployment pattern**: each server gets a Deployment + ClusterIP
  Service in `claude-agents` namespace; URL injected into agent config as
  `http://<service>.<namespace>.svc.cluster.local:<port>/sse`.

## Consequences

- **Easier:** Adding new integrations (Slack, Jira, custom APIs) is a Helm
  template + config update — no image build cycle.
- **Easier:** Different agent roles can get different MCP capabilities without
  separate images.
- **Harder:** MCP servers must be running and healthy for agents to use them;
  adds in-cluster service dependencies to debug.
- **Watch for:** MCP server availability during agent pod startup — agents should
  degrade gracefully if an MCP server is unreachable rather than failing the task.
- **Watch for:** Secrets for MCP servers (GitHub tokens, API keys) must be
  managed as K8s secrets and injected via env vars into MCP server pods, not
  into agent pods.
- **GitHub PAT scopes (updated 2026-05-10):** The PAT used by the GitHub MCP
  server requires: Contents (read/write), Pull requests (read/write), Issues
  (read), Metadata (read). If agents need to create new repositories, also add
  Administration (read/write) — this scope was added to the PAT on 2026-05-10.
