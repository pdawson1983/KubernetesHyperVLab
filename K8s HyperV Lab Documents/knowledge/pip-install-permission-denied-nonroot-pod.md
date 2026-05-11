# pip install Permission Denied in Non-Root Pod

**Date:** 2026-05-10

## Symptoms

Running `pip install <package>` inside a Kubernetes pod that has a pod-level
`securityContext.runAsUser` set (e.g. 1001) fails with:

```
ERROR: Could not install packages due to an OSError: [Errno 13] Permission denied: '/.local'
Check the permissions.
```

## Root Cause

pip's user-install mode tries to write to `$HOME/.local`. When the pod runs as
a UID that has no home directory entry in `/etc/passwd` (common for arbitrary
UIDs like 1001 in base images), `$HOME` defaults to `/` which is not writable.

The `python:3.12-slim` image is the affected base; the dispatcher pod runs with
`runAsUser: 1001` inherited from the pod-level securityContext.

## Fix

Install to a writable temp directory using `--target`:

```python
import subprocess, sys, os
try:
    import pg8000.native
except ImportError:
    subprocess.check_call([sys.executable, '-m', 'pip', 'install',
        '--quiet', '--no-cache-dir', '--target', '/tmp/pypkgs', 'pg8000'])
    sys.path.insert(0, '/tmp/pypkgs')
    import pg8000.native
```

The `try/except ImportError` skips the install if the package is already
available (e.g. on pod restart if `/tmp` is preserved).

## Prevention

- For sidecar containers that need pip packages at runtime, use `--target /tmp/...`
  and add the path to `sys.path`.
- For production use, build a custom image with the packages pre-installed to
  avoid startup latency and network dependency.
- Alternatively, set `HOME=/tmp` as an env var, but `--target` is more explicit.
