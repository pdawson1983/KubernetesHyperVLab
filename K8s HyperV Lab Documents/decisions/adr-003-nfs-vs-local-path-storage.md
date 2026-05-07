# ADR: NFS for Agent Memory, local-path for Registry

**Date:** 2026-05-07
**Status:** accepted

## Context

Two PVCs are needed:
1. **Agent memory** (`/memory`) — read and written by all five agent pods, which may run on different nodes simultaneously. Requires ReadWriteMany (RWX).
2. **Registry storage** — written by one registry pod, read by containerd on each node at pull time. ReadWriteOnce (RWO) is sufficient.

## Decision

- Agent memory → NFS StorageClass, backed by NFS server on k8s-control (`/srv/nfs/k8s`). RWX, 10Gi.
- Registry storage → local-path StorageClass (Rancher local-path-provisioner). RWO, 20Gi.

## Consequences

- **NFS for memory:** Simplest RWX option without adding Longhorn, Rook-Ceph, or another distributed storage layer to a 3-node lab cluster. NFS latency is acceptable for file-based inter-agent messaging. Single point of failure is k8s-control — acceptable for a lab.
- **local-path for registry:** Faster than NFS for small random reads (container layer pulls). No extra infrastructure needed. Bound to whichever node the registry pod lands on — if the pod moves to a different node, the PVC stays behind and the pod won't start. Acceptable given registry runs as a single replica.
- **Watch for:** If k8s-control goes down, NFS is unavailable and all agent runs fail. No mitigation planned for lab use.
- **Watch for:** The NFS PVC has `helm.sh/resource-policy: keep` — it is NOT deleted on `helm uninstall`. This preserves agent memory across chart upgrades but requires manual cleanup if a fresh start is needed.
