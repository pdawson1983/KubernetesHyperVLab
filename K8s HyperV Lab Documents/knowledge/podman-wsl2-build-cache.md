# Podman Build Cache False Hits on WSL2

**Date:** 2026-05-07

## Symptoms

After editing files in the project (e.g., `entrypoint.sh`, `agent-base.md`) and
running `podman build`, the build completes with the same image digest as before.
The pushed image on Docker Hub also shows the same config hash. The `Copying blob`
output during push shows only 2–3 blobs instead of all layers, suggesting most
layers were considered unchanged.

Running `podman build --no-cache` produces a different local image ID but the push
still shows the same manifest config hash on Docker Hub.

## Root Cause

Two separate issues:

1. **WSL2 filesystem mtime** — podman accesses project files through the WSL2 mount
   of the Windows filesystem (`/mnt/c/...`). Windows NTFS does not expose POSIX
   mtimes correctly through the WSL2 DrvFs layer. Podman's layer cache uses file
   content hashing to detect changes, but under certain conditions the hash is
   computed against stale data.

2. **Docker Hub manifest deduplication** — when pushing, Docker Hub computes the
   manifest config hash from layer digests. If the layer content is byte-for-byte
   identical to a previously pushed layer (even from a `--no-cache` build that
   produced the same content), the manifest hash will be identical. This is correct
   behaviour — it does not mean the push failed.

## Fix

Always verify the image actually contains expected changes before trusting the
build:

```bash
# Verify a specific string exists in the built image
podman run --rm --entrypoint grep claude-agent:latest \
  -c "AGENT_MOCK" /agent/entrypoint.sh
# Prints the match count — if > 0, the file has the expected content

# Or inspect the full file
podman run --rm --entrypoint cat claude-agent:latest /agent/entrypoint.sh | head -50
```

If the content is wrong, force a clean build:

```bash
podman build --no-cache -t claude-agent:latest .
```

Note: `--no-cache` prevents layer reuse within the build but does not affect Docker
Hub's manifest deduplication. A build that produces identical layer content will
always produce the same manifest hash regardless of `--no-cache`.

## Prevention

- Always use `podman build --no-cache` when building from the WSL2-mounted Windows
  filesystem. The cache savings are not worth the risk of a stale image.
- Add a verification step after build and before push:
  ```bash
  podman run --rm --entrypoint grep claude-agent:latest -c "EXPECTED_STRING" /agent/entrypoint.sh
  ```
- Document the expected verification string in the build instructions so future
  sessions know what to check.
