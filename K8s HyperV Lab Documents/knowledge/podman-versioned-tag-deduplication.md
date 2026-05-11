# Podman Push Deduplication with Versioned Tags

**Date:** 2026-05-11

## Symptoms

After `podman build --no-cache` produces a new image ID locally, `podman push`
to the local registry appears to succeed but the registry serves the old image.
The pushed config hash matches the previous push even though the local image ID
is different.

```
Copying config sha256:7dee2dd8...   ← same hash as last push
Writing manifest to image destination
Storing signatures
```

Pods pull the old image despite the new tag being present in the registry.

## Root Cause

Podman (and Docker) deduplication: if layer content is identical between two
builds, the manifest config hash matches. The registry deduplicates and serves
the cached manifest for the same tag. This affects both `:latest` pushes and
versioned tags when the source files haven't changed between builds.

For the web UI image specifically, two rapid rebuilds with identical
`requirements.txt` and identical template files produce the same layer hashes.

## Fix

Force a cache-bust by using `--no-cache` AND verifying the config hash has
changed before deploying:

```bash
# Build
podman build --no-cache -t agentforge-webui:latest .

# Check that the hash is new — compare with previous
podman inspect agentforge-webui:latest --format '{{.Id}}'

# Push with versioned tag
WEBUI_TAG="$(date -u +%Y%m%d-%H%M%S)"
podman tag agentforge-webui:latest 192.168.100.11:30500/agentforge-webui:${WEBUI_TAG}
podman push 192.168.100.11:30500/agentforge-webui:${WEBUI_TAG} --tls-verify=false

# Verify the pushed digest differs from the previous tag
```

If the hash is still the same after `--no-cache`, touch a file or add a
`ARG BUILD_DATE` build argument (as the agent image does) to force a layer
difference:

```dockerfile
ARG BUILD_DATE=unknown
LABEL build-date=$BUILD_DATE
```

```bash
podman build --no-cache --build-arg BUILD_DATE="$(date -u +%Y%m%d-%H%M%S)" -t agentforge-webui:latest .
```

## Prevention

Add `ARG BUILD_DATE` + `LABEL build-date=$BUILD_DATE` to the web UI Dockerfile
(same pattern as `claude-agent/claude-agent-image/Dockerfile`) so every build
is guaranteed to produce a unique manifest. See ADR-007.
