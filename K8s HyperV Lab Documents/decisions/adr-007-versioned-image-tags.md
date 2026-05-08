# ADR: Versioned Image Tags Over :latest

**Date:** 2026-05-08
**Status:** accepted

## Context

The claude-agent image was built with `podman build --no-cache` and pushed to Docker Hub
under the `:latest` tag after changes to `entrypoint.sh` and `agent-base.md`. Despite the
`--no-cache` flag, the pushed manifest config hash matched the previous push
(`8b3e6aed2f2...`). Nodes running with `pullPolicy: Always` pulled from Docker Hub, received
the old image (Docker Hub's manifest for `:latest` was unchanged), and ran the old
entrypoint without mock mode support.

The root cause is Docker Hub manifest deduplication: if the image layer content hashes
match a prior push, Docker Hub returns the same manifest digest for `:latest` even after
a re-push. With `pullPolicy: Always`, containerd checks the manifest digest against its
cache; if they match, it uses the cached (old) image. The net result: the node silently
ran old code despite a supposed image update.

Additionally, `pullPolicy: Always` causes every agent Job startup to make a network
request to Docker Hub, creating a dependency on internet connectivity and Docker Hub
availability for every pipeline run, and risking rate limits under heavy use.

## Decision

1. **Versioned tags for every image push.** Tags use the format `YYYYMMDD-HHMMSS`
   (e.g., `20260508-023415`). Each push gets a unique tag that is never reused. Docker Hub
   cannot deduplicate distinct tags — a new tag always creates a new manifest entry.

2. **`pullPolicy: IfNotPresent`.** Nodes pull the image once on first use and cache it.
   Subsequent jobs use the cached image with no network round-trip to Docker Hub.

3. **`values.yaml` pins the current tag.** After each push, `global.image.tag` is updated
   manually in `values.yaml` and a `helm upgrade` is run. The chart becomes the source of
   truth for which image version is active.

4. **`BUILD_DATE` ARG in Dockerfile.** `--build-arg BUILD_DATE=$(date -u +%Y%m%d-%H%M%SZ)`
   is passed at build time. This injects a unique `LABEL build-date=...` into the image
   config, changing the manifest hash even if file content is otherwise identical.

5. **Mandatory verification step.** Before pushing, verify the local image contains
   expected changes:
   `podman run --rm --entrypoint grep claude-agent:latest -c "AGENT_MOCK" /agent/entrypoint.sh`

## Consequences

- **Stale image problem eliminated.** Nodes always run exactly the image version pinned
  in `values.yaml`. No silent cache hits.
- **Reduced Docker Hub dependency.** After first pull per node, no internet needed for
  agent job starts. Rate limits are no longer a concern under normal use.
- **values.yaml is always authoritative.** The running image version is visible in git.
- **Manual tag update required.** Updating the image now requires editing `values.yaml`
  and running `helm upgrade` in addition to build + push. This is an acceptable trade-off
  for the reliability gained.
- **Watch for:** old image versions accumulate on Docker Hub. Consider pruning tags older
  than 30 days once the local registry is active and Docker Hub is no longer the primary.
- **Local registry will improve this further.** Pushing to `192.168.100.11:30500` removes
  the Docker Hub dependency entirely. The versioned tag workflow applies equally to the
  local registry.
