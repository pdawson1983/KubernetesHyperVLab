# Worker Nodes: LVM Volumes Were Not Extended at Install Time

**Date discovered:** 2026-05-07

## Symptom

Agent pods (coder) were immediately evicted with:
```
The node was low on resource: ephemeral-storage. Threshold quantity: ~1GB, available: ~988MB
```

Both workers showed `df -h /` at 82–83% with only ~1.7GB free despite the VMs having 20GB virtual disks.

## Cause

Ubuntu's installer created a 20GB virtual disk but only extended the LVM logical volume (`ubuntu-vg/ubuntu-lv`) to ~10GB. The remaining ~10GB of the physical disk was unallocated.

## Fix Applied

Run on each worker via a privileged `nsenter` pod (no SSH required):

```bash
kubectl run lvm-expand-workerN \
  --image=ubuntu:22.04 \
  --restart=Never \
  --overrides='{"spec":{"nodeName":"k8s-workerN","hostPID":true,"hostIPC":true,"hostNetwork":true,"containers":[{"name":"lvm-expand","image":"ubuntu:22.04","command":["nsenter","--target","1","--mount","--uts","--ipc","--net","--pid","--","bash","-c","pvresize $(pvs --noheadings -o pv_name | tr -d \" \") && lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv && resize2fs /dev/ubuntu-vg/ubuntu-lv && df -h /"],"securityContext":{"privileged":true}}]}}' \
  -n default
```

Result: both workers expanded from 10GB to 17GB LV (3GB reserved by LVM metadata), now at ~45% usage.

## Check Control Plane Too

The control plane (`k8s-control`) was also provisioned with the same installer and likely has the same gap. It has more free space (only hosts the NFS server + control plane components) but should be expanded proactively with the same command targeting `nodeName: k8s-control`.

## Prevention

After provisioning Ubuntu VMs with LVM, always run:
```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv && sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```
Or use `--grow` in the installer's storage config to auto-fill the disk.
