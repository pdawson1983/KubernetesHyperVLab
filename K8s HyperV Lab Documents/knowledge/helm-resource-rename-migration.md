# Helm Resource Rename Migration

**Date:** 2026-05-10

## Symptoms

Changing `fullnameOverride` or `global.namespace` in values.yaml and running
`helm upgrade` fails with one or more of these errors:

```
Error: UPGRADE FAILED: failed to create resource: Service "<new-name>" is invalid:
  spec.ports[0].nodePort: Invalid value: 30500: provided port is already allocated

Error: UPGRADE FAILED: admission webhook "validate.nginx.ingress.kubernetes.io"
  denied the request: host "webhook.k8s.local" and path "/" is already defined
  in ingress claude-agents/<old-ingress-name>
```

## Root Cause

Helm creates new resources before deleting old ones during an upgrade. When the
resource names change (due to fullname or namespace change), the old resources
still hold exclusive claims to:
- NodePort numbers (registry :30500)
- Ingress host+path combinations

Helm can't atomically swap them.

## Fix

Delete all old resources first, then upgrade/install:

```bash
# Clear services, deployments, cronjobs, ingresses, RBAC
kubectl delete service,deployment,cronjob,ingress,serviceaccount,role,rolebinding \
  -l app.kubernetes.io/instance=<release-name> \
  -n <old-namespace> \
  --ignore-not-found

# For namespace migration: uninstall entirely, then install fresh
helm uninstall <release> -n <old-namespace>
kubectl create namespace <new-namespace>
# Annotate if namespace was pre-created manually:
kubectl annotate namespace <new-namespace> \
  meta.helm.sh/release-name=<release> \
  meta.helm.sh/release-namespace=<new-namespace>
kubectl label namespace <new-namespace> app.kubernetes.io/managed-by=Helm
helm install <release> . -n <new-namespace>
```

## After Migration

1. **Re-push the container image** — new registry PVC starts empty:
   ```bash
   podman push 192.168.100.11:30500/claude-agent:<tag> --tls-verify=false
   ```
2. **Recreate secrets** — secrets are namespace-scoped and must be recreated:
   - `webhook-secret`, `claude-credentials`, `github-token`, `postgres-credentials`
   - `registry-tls` (from `/tmp/registry-tls/` — not in git)
3. **Clean up old PVCs** — PVCs with `resource-policy: keep` survive uninstall
   and must be deleted manually once the new namespace is verified working.

## Prevention

- Keep `fullnameOverride` and `global.namespace` stable once set.
- Before any rename, capture all secret values first.
- If only resource names change (not namespace), `kubectl delete` of conflicting
  resources (NodePort services, Ingress) is sufficient before `helm upgrade`.
