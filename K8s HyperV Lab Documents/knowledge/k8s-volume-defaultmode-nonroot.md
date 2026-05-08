# Kubernetes Secret Volume defaultMode Must Be World-Readable for Non-Root Pods

**Date:** 2026-05-08

## Symptoms

Agent pod starts, logs show:
```
cp: cannot open '/home/agent/.claude-creds/.credentials.json' for reading: Permission denied
```

The pod exits with non-zero and shows `Error` status, even though the secret exists
and was mounted correctly.

## Root Cause

Kubernetes secret volumes are owned by `root` (UID 0) by default. The `defaultMode`
field controls the file permission bits. The Helm template had:

```yaml
- name: claude-credentials
  secret:
    secretName: claude-credentials
    defaultMode: 0400   # owner read-only — owner is root
```

`0400` means only the file owner (root) can read it. The agent container runs as
UID 1001 (`agent` user), which is not the owner and has no group membership that
grants access. The `cp` command fails with Permission denied.

## Fix

Change `defaultMode` to `0444` (world-readable):

```yaml
- name: claude-credentials
  secret:
    secretName: claude-credentials
    defaultMode: 0444   # all users can read
```

After changing in `helm/claude-agents-v6/templates/_helpers.tpl`, run
`helm upgrade claude-agents . -n claude-agents`.

## Prevention

- When mounting secrets into pods that run as non-root users, always use
  `defaultMode: 0444` unless you have a specific reason to restrict further.
- The alternative is to set `fsGroup` in the pod's `securityContext` to match the
  container's GID, and use `0440` (owner + group readable). This requires the secret
  volume's group ownership to be set via `fsGroup`.
- A third option: use an init container to copy the secret file to an emptyDir and
  `chown` it to the target UID. This is more complex but gives full control.
- For credentials specifically: `0444` is acceptable since the secret is already
  access-controlled at the Kubernetes RBAC level — only pods in the namespace that
  reference the secret name can mount it.
