# Kubernetes Cluster on Hyper-V with WSL Access
### Ubuntu 22.04 LTS · Multi-Node · Windows 11

---

## Architecture

| Node | Hostname | IP | Role | RAM | vCPU |
|------|----------|----|------|-----|------|
| Control plane | k8s-control | 192.168.100.10 | API server, etcd, scheduler | 4 GB | 2 |
| Worker 1 | k8s-worker1 | 192.168.100.11 | Workloads | 4 GB | 2 |
| Worker 2 | k8s-worker2 | 192.168.100.12 | Workloads | 4 GB | 2 |

**Host requirements:** Windows 10/11 Pro, Enterprise, or Education · 16+ GB RAM · 60+ GB free disk · Hyper-V capable CPU

---

## Part 1 — Windows Host Setup

### Step 1 — Enable Hyper-V

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

Reboot, then confirm:

```powershell
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
```

---

### Step 2 — Create Internal Virtual Switch with NAT

```powershell
# Create the switch
New-VMSwitch -Name "K8sSwitch" -SwitchType Internal

# Find the interface index (note the number it returns)
Get-NetAdapter | Where-Object {$_.Name -like "*K8sSwitch*"}

# Assign host-side IP (replace 24 with your actual InterfaceIndex)
New-NetIPAddress -IPAddress 192.168.100.1 -PrefixLength 24 -InterfaceIndex 24

# Set up NAT for internet access
New-NetNat -Name "K8sNAT" -InternalIPInterfaceAddressPrefix 192.168.100.0/24
```

---

### Step 3 — Create the VMs

Run this block three times, changing `$VMName` each time:

```powershell
$VMName = "k8s-control"   # change to k8s-worker1, k8s-worker2
$ISOPath = "C:\ISOs\ubuntu-22.04.5-live-server-amd64.iso"

New-VM -Name $VMName -MemoryStartupBytes 4GB -Generation 2 -SwitchName "K8sSwitch"
Set-VMProcessor -VMName $VMName -Count 2
New-VHD -Path "C:\Hyper-V\$VMName\$VMName.vhdx" -SizeBytes 20GB -Dynamic
Add-VMHardDiskDrive -VMName $VMName -Path "C:\Hyper-V\$VMName\$VMName.vhdx"
Add-VMDvdDrive -VMName $VMName -Path $ISOPath
Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMDvdDrive -VMName $VMName)
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Start-VM -VMName $VMName
```

**During Ubuntu installation, assign static IPs:**
- `k8s-control` → `192.168.100.10/24`, gateway `192.168.100.1`
- `k8s-worker1` → `192.168.100.11/24`, gateway `192.168.100.1`
- `k8s-worker2` → `192.168.100.12/24`, gateway `192.168.100.1`

Set DNS to `8.8.8.8`. After install, eject the DVD and reboot each VM.

---

### Step 4 — Fix Console Blanking (Hyper-V Console Freeze)

On each VM, edit GRUB to prevent the console from freezing:

```bash
sudo nano /etc/default/grub
```

Change:
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
```
To:
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash consoleblank=0"
```

Then:
```bash
sudo update-grub
sudo reboot
```

---

## Part 2 — Prepare All Three Nodes

Run this entire script on **each VM** (control plane and both workers):

```bash
# ── 1. Disable swap ──────────────────────────────────────────────
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# ── 2. Load required kernel modules ─────────────────────────────
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# ── 3. Kernel networking settings ───────────────────────────────
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# ── 4. Install containerd ────────────────────────────────────────
sudo apt-get update && sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd && sudo systemctl enable containerd

# ── 5. Verify cgroup v2 (required on 22.04) ──────────────────────
stat -fc %T /sys/fs/cgroup/
# Should return: tmpfs (22.04 uses cgroup v1 by default — that's fine)

# ── 6. Install kubeadm, kubelet, kubectl ─────────────────────────
sudo apt-get install -y apt-transport-https ca-certificates curl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

**What each section does:**

| Section | Why it's needed |
|---------|----------------|
| Disable swap | Kubernetes scheduler requires predictable memory — swap breaks its calculations |
| overlay module | Enables layered container filesystems |
| br_netfilter module | Lets iptables see pod-to-pod bridge traffic |
| Sysctl settings | Enables IP forwarding and bridge traffic filtering |
| containerd | The container runtime Kubernetes uses |
| SystemdCgroup = true | Prevents cgroup management conflicts between containerd and systemd |
| kubeadm | One-time cluster setup tool |
| kubelet | Node agent that keeps pods running |
| kubectl | CLI to interact with the cluster |
| apt-mark hold | Prevents accidental version upgrades that could break the cluster |

---

## Part 3 — Initialize the Control Plane

On **k8s-control only:**

```bash
sudo kubeadm init \
  --apiserver-advertise-address=192.168.100.10 \
  --pod-network-cidr=10.244.0.0/16

# Set up kubectl for your user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install Flannel CNI
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```

> **Important:** Save the `kubeadm join` command printed at the end — you need it for the next step.

---

## Part 4 — Join Worker Nodes

On **each worker**, paste the join command from the previous step:

```bash
sudo kubeadm join 192.168.100.10:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
  
  
sudo kubeadm join 192.168.100.10:6443 --token 9v5jq0.1b87s6x58y6n5f98 --discovery-token-ca-cert-hash sha256:d67235f4448cef338ffb5a4dd1e13c73df4c89e85d8117f026d11663c179bff2
```

If the token expires (they last 24 hours), generate a new one on the control plane:

```bash
kubeadm token create --print-join-command
```

---

## Part 5 — Verify the Cluster

Back on the control plane:

```bash
kubectl get nodes -o wide
```

All three nodes should show `Ready` within a minute or two. Run a quick test:

```bash
kubectl run nginx --image=nginx
kubectl get pods -o wide   # confirm pod is scheduled to a worker
```

---

## Part 6 — WSL Access

### Install kubectl in WSL

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubectl
```

### Copy Kubeconfig from Control Plane

First generate an SSH key in WSL if you don't have one:

```bash
ssh-keygen -t ed25519 -C "wsl-k8s"
ssh-copy-id your-username@192.168.100.10
ssh-copy-id your-username@192.168.100.11
ssh-copy-id your-username@192.168.100.12
```

Then pull the kubeconfig:

```bash
mkdir -p ~/.kube
scp your-username@192.168.100.10:~/.kube/config ~/.kube/config
chmod 600 ~/.kube/config

# Verify the server address
grep server ~/.kube/config
# Should show: server: https://192.168.100.10:6443
```

### Fix WSL → Hyper-V Routing

WSL2 has its own network namespace. Add a route so it can reach the K8s subnet:

```bash
# From inside WSL — find your default gateway
ip route show | grep default
# Note the 172.x.x.x address

# Add the route
sudo ip route add 192.168.100.0/24 via <172.x.x.x gateway>
```

Also enable forwarding on Windows (run in PowerShell as admin):

```powershell
Set-NetIPInterface -InterfaceAlias "vEthernet (K8sSwitch)" -Forwarding Enabled
Set-NetIPInterface -InterfaceAlias "vEthernet (WSL (Hyper-V firewall))" -Forwarding Enabled
```

Verify connectivity from WSL:

```bash
ping 192.168.100.10
kubectl get nodes -o wide
```

### Make the Route Persistent

The WSL route doesn't survive reboots. Create a startup script:

Save as `C:\Scripts\wsl-k8s-route.ps1`:

```powershell
$wslGW = (wsl -- ip route show | Select-String "default" | ForEach-Object { ($_ -split " ")[2] })
wsl -- sudo ip route add 192.168.100.0/24 via $wslGW 2>$null
Set-NetIPInterface -InterfaceAlias "vEthernet (K8sSwitch)" -Forwarding Enabled
Set-NetIPInterface -InterfaceAlias "vEthernet (WSL (Hyper-V firewall))" -Forwarding Enabled
```

Register as a scheduled task:

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
             -Argument "-NonInteractive -WindowStyle Hidden -File C:\Scripts\wsl-k8s-route.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable
Register-ScheduledTask -TaskName "WSL-K8s-Route" -Action $action `
  -Trigger $trigger -RunLevel Highest -Settings $settings
```

Test it manually:

```powershell
Start-ScheduledTask -TaskName "WSL-K8s-Route"
Get-ScheduledTaskInfo -TaskName "WSL-K8s-Route"
# LastTaskResult of 0 = success
```

### SSH Config Shortcuts

Add to `~/.ssh/config` in WSL:

```
Host k8s-control
  HostName 192.168.100.10
  User your-username
  IdentityFile ~/.ssh/id_ed25519

Host k8s-worker1
  HostName 192.168.100.11
  User your-username
  IdentityFile ~/.ssh/id_ed25519

Host k8s-worker2
  HostName 192.168.100.12
  User your-username
  IdentityFile ~/.ssh/id_ed25519
```

### WSL Quality of Life

Add to `~/.bashrc`:

```bash
# kubectl autocomplete
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k

# Quick shortcuts
alias kgn='kubectl get nodes -o wide'
alias kgp='kubectl get pods -A'
alias kctx='kubectl config current-context'
alias kns='kubectl config set-context --current --namespace'
```

```bash
source ~/.bashrc
```

---

## Troubleshooting

### VM runs out of memory (OOM killer / kernel panic)

```powershell
# Increase VM RAM (shut down VM first)
Set-VM -VMName "k8s-control" -MemoryStartupBytes 4GB
Set-VM -VMName "k8s-worker1" -MemoryStartupBytes 4GB
Set-VM -VMName "k8s-worker2" -MemoryStartupBytes 4GB
```

### Can't shut down a crashed VM

```powershell
Stop-VM -VMName "k8s-worker1" -Force
# If that fails:
Get-Process vmwp | Stop-Process -Force
```

### WSL can't ping VMs

```powershell
# Check forwarding is enabled
Get-NetIPInterface | Select-Object InterfaceAlias, Forwarding | Sort-Object InterfaceAlias
# K8sSwitch and WSL adapter should show Enabled

# Re-add the route from inside WSL
sudo ip route add 192.168.100.0/24 via 172.x.x.x
```

### SSH permission denied (publickey)

Ubuntu may have a config override in `/etc/ssh/sshd_config.d/`. Check on the VM:

```bash
sudo grep -r "PasswordAuthentication" /etc/ssh/
sudo nano /etc/ssh/sshd_config.d/50-cloud-init.conf
# Set: PasswordAuthentication yes
sudo systemctl restart ssh
```

Then run `ssh-copy-id` from WSL, then set it back to `no`.

### Token expired when joining workers

```bash
# On control plane — generate a new join command
kubeadm token create --print-join-command
```

---

## Taking Snapshots

Take Hyper-V snapshots at key points so you can roll back quickly:

```powershell
# After node prep (Step 4) — before kubeadm
Checkpoint-VM -VMName "k8s-control" -SnapshotName "pre-kubeadm"
Checkpoint-VM -VMName "k8s-worker1" -SnapshotName "pre-kubeadm"
Checkpoint-VM -VMName "k8s-worker2" -SnapshotName "pre-kubeadm"

# After cluster is healthy
Checkpoint-VM -VMName "k8s-control" -SnapshotName "cluster-ready"
Checkpoint-VM -VMName "k8s-worker1" -SnapshotName "cluster-ready"
Checkpoint-VM -VMName "k8s-worker2" -SnapshotName "cluster-ready"
```

---

## Next Steps

Once the cluster is running, natural next steps include:

- **Helm** — package manager for Kubernetes (`apt-get install helm`)
- **Ingress controller** — expose services via hostname (nginx-ingress or Traefik)
- **Local container registry** — avoid pulling from Docker Hub every time
- **Persistent storage** — local-path-provisioner for PVCs in a lab
- **Metrics server** — enables `kubectl top nodes` and `kubectl top pods`
- **Dashboard** — web UI for the cluster
