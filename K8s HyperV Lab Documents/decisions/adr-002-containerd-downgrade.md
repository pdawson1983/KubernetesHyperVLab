# ADR: Downgrade containerd 2.2.1 → 1.7.24

**Date:** 2026-05-07
**Status:** accepted

## Context

containerd 2.2.1 has a bug where `hosts.toml` configuration is ignored by the transfer plugin. This meant the insecure local registry at `192.168.100.11:30500` could not be used for image pulls from cluster nodes, even with a correctly written `hosts.toml`. All agent pods failed to pull the image.

## Decision

Downgrade all cluster nodes to containerd 1.7.24, where `hosts.toml` is correctly honored.

## Consequences

- **Easier:** `hosts.toml`-based insecure registry config works as documented.
- **Watch for:** The local registry at `:30500` was not re-validated after the downgrade. It may now work — test with `curl http://192.168.100.11:30500/v2/_catalog` before switching from Docker Hub.
- **Watch for:** 1.7.24 is an older release. Monitor for CVEs and plan an upgrade path once the 2.x registry bug is patched upstream or a workaround is confirmed.
- **Current state:** Docker Hub (`docker.io/pdawson/claude-agent:latest`) is used as a workaround until local registry is re-validated.
