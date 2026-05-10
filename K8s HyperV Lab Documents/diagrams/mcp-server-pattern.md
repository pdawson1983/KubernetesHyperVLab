# MCP Server Pattern

AgentForge uses in-cluster MCP (Model Context Protocol) servers as its extensibility
mechanism. New external system integrations are added by deploying a new MCP server —
no agent image rebuild required. See ADR-011.

```mermaid
graph TB
    subgraph Cluster["claude-agents namespace"]
        subgraph AgentPod["Agent Pod (e.g. coder)"]
            EP["entrypoint.sh"]
            Settings["~/.claude/settings.json\n{mcpServers: {github: {url: ...}}}"]
            Claude["claude --print"]
            EP -->|"1. read mcpServers\n   from queue file"| EP
            EP -->|"2. write"| Settings
            Settings -->|"3. loaded at startup"| Claude
        end

        subgraph MCP["MCP Servers (ClusterIP)"]
            GH["github-mcp-server\nDeployment\n:8080/sse"]
            Future1["future-mcp-server-2\n(e.g. Jira)"]
            Future2["future-mcp-server-N\n(e.g. Slack)"]
        end

        Claude -->|"SSE connection\nMCP_GITHUB_URL"| GH
        Claude -.->|"future"| Future1
        Claude -.->|"future"| Future2
    end

    subgraph External["External Systems"]
        GitHub["GitHub API\nrepos, PRs, issues"]
    end

    GH -->|"GITHUB_TOKEN\nfrom K8s Secret"| GitHub

    subgraph HelmValues["values.yaml"]
        V1["mcp.servers.github.enabled: true"]
        V2["mcp.servers.github.tokenSecret: github-token"]
    end

    HelmValues -->|"Helm injects\nMCP_GITHUB_URL env var\ninto all agent pods"| AgentPod
```

## How the Architect Controls Access

The architect writes queue files for downstream agents. Including `mcpServers` in
a queue file grants that agent access to the listed servers at runtime.

```mermaid
graph LR
    Arch["Architect\nqueue/coder.json\n{mcpServers: ['github']}"]
    Arch2["Architect\nqueue/reviewer.json\n{}  (no mcpServers)"]

    Coder["Coder pod\ngets GitHub MCP\n→ can clone, push"]
    Reviewer["Reviewer pod\nno MCP servers\n→ reads workspace only"]

    Arch --> Coder
    Arch2 --> Reviewer
```

## Adding a New MCP Server

1. Add a new block under `mcp.servers` in `values.yaml` with image, port, tokenSecret
2. Add a new `templates/mcp/<name>-mcp-server.yaml` (Deployment + ClusterIP Service)
3. Add a new `url_map` entry in `entrypoint.sh` for the server name
4. Add a new `MCP_<NAME>_URL` env var injection in `_helpers.tpl` `claude-agents.mcpEnv`
5. Document the server in the Available servers table in `agent-base.md`
6. `helm upgrade` — no image rebuild needed

## Deployed MCP Servers

| Name | Image | Status | Provides |
|------|-------|--------|----------|
| `github` | `ghcr.io/github/github-mcp-server` | Implemented (disabled until token secret created) | Repo clone/push, PR create, issue read |
