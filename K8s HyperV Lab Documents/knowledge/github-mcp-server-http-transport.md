# GitHub MCP Server — HTTP Transport Command

**Date:** 2026-05-10

## Symptoms

`ghcr.io/github/github-mcp-server` pod crashes immediately with:

```
unknown flag: --transport
```

when the container args include `--transport sse --port 8080 --host 0.0.0.0`.

## Root Cause

The GitHub MCP server CLI does not have a `--transport` flag. The MCP transport
is selected via a **subcommand**, not a flag:

- `github-mcp-server stdio` — stdio transport (for Claude Desktop / local use)
- `github-mcp-server http --port 8082` — HTTP transport (for in-cluster use)

The default port for HTTP mode is **8082**, not 8080.

## Fix

Set the Deployment args to:

```yaml
args:
  - "http"
  - "--port"
  - "8080"
```

The `PORT` env var is also passed as a belt-and-suspenders measure but the
`--port` flag is what the image actually reads.

## Startup Log (Healthy)

```
level=INFO msg="starting server" version=v1.0.3
level=INFO msg="MCP endpoints registered" baseURL=""
level=INFO msg="HTTP server listening" addr=:8080
```

## Claude Code Settings.json

For HTTP transport, use `type: "http"` (not `"sse"`):

```json
{
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "http://agentforge-github-mcp.agentforge.svc.cluster.local:8080"
    }
  }
}
```

## Prevention

When adding a new MCP server, always probe the image first before setting args:

```bash
kubectl run mcp-probe --rm -i --restart=Never \
  --image=<image> -n agentforge -- --help
# Then check subcommands:
kubectl run mcp-probe --rm -i --restart=Never \
  --image=<image> -n agentforge -- http --help
```
