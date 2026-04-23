# NKP (Nutanix Kubernetes Platform) Installation Guide for vSphere

## Overview

This guide provides step-by-step instructions for deploying a small-scale NKP cluster on vSphere using Ubuntu 22.04 as the base operating system. NKP 2.16+ supports Ubuntu 22.04 with Ubuntu Pro enabled for security patching.

**Architecture:**
- Management Cluster: Self-managed cluster that controls other clusters
- Workload Clusters: Where your applications run (optional for lab)

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Prepare the Bastion Host](#2-prepare-the-bastion-host)
3. [Create the Base VM Template in vSphere](#3-create-the-base-vm-template-in-vsphere)
4. [Build the CAPI VM Template with KIB](#4-build-the-capi-vm-template-with-kib)
5. [Create the Management Cluster](#5-create-the-management-cluster)
6. [Access the NKP Dashboard](#6-access-the-nkp-dashboard)
7. [Create a Workload Cluster (Optional)](#7-create-a-workload-cluster-optional)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Prerequisites

### 1.1 vSphere Requirements

| Requirement | Details |
|-------------|---------|
| vCenter Server | 7.0 U2+ or 8.0+ |
| ESXi Hosts | 7.0 U2+ or 8.0+ |
| User Permissions | Administrator or equivalent role with VM provisioning rights |
| Datastore | At least 500GB free space for templates and VMs |
| Network | DHCP or static IP range available |

### 1.2 Network Requirements

| Component | IP Addresses Needed |
|-----------|---------------------|
| Control Plane Endpoint (VIP) | 1 static IP |
| Control Plane Nodes | 1-3 IPs (3 for HA production) |
| Worker Nodes | 1-4 IPs (based on cluster size) |
| Load Balancer Range (MetalLB) | Range of IPs (e.g., 10 IPs) |

### 1.3 Small Lab Sizing (Minimum)

| Component | Count | vCPU | Memory | Disk |
|-----------|-------|------|--------|------|
| Bastion Host | 1 | 2 | 8 GB | 300 GB |
| Control Plane | 1 (lab) / 3 (HA) | 4 | 16 GB | 80 GB |
| Worker Nodes | 2-4 | 8 | 32 GB | 80 GB |

> **Note:** For production, use 3 control plane nodes for high availability.

### 1.4 Software Requirements

- NKP CLI binary (download from Nutanix Portal)
- Docker or Podman (version 4+)
- kubectl
- SSH key pair

### 1.5 Credentials Needed

- vCenter username and password
- Nutanix Portal account (for downloading NKP)
- Docker Hub credentials (optional, to avoid rate limits)

---

## 2. Prepare the Bastion Host

The bastion host is your deployment machine. You can use Ubuntu 22.04 for this.

### 2.1 Deploy Ubuntu 22.04 VM in vSphere

1. Download Ubuntu 22.04 Server ISO from [ubuntu.com](https://ubuntu.com/download/server)
2. Upload the ISO to your vSphere datastore
3. Create a new VM:
   - **Guest OS:** Ubuntu Linux (64-bit)
   - **vCPU:** 2
   - **Memory:** 8 GB
   - **Disk:** 300 GB (for NKP bundles and images)
   - **Network:** Connected to your management network
4. Install Ubuntu 22.04 with minimal server configuration
5. Enable SSH access

### 2.2 Install Docker on Bastion Host

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install prerequisites
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg

# Add Docker GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Enable and start Docker
sudo systemctl enable --now docker

# Add current user to docker group
sudo usermod -aG docker $USER

# Apply group changes (or logout/login)
newgrp docker

# Verify installation
docker --version
docker ps
```

### 2.3 Install kubectl

```bash
# Download latest kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Install kubectl
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

# Verify installation
kubectl version --client

# Enable bash completion (optional but recommended)
sudo apt install -y bash-completion
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc
source ~/.bashrc
```

### 2.4 Install Helm (Optional)

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
echo 'source <(helm completion bash)' >> ~/.bashrc
source ~/.bashrc
```

### 2.5 Install K9s (Optional - TUI for Kubernetes)

```bash
wget https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz
tar zxvf k9s_Linux_amd64.tar.gz
sudo mv k9s /usr/local/bin/
rm -f k9s_Linux_amd64.tar.gz LICENSE README.md
```

### 2.6 Download and Install NKP CLI

1. Log in to [Nutanix Portal](https://portal.nutanix.com)
2. Navigate to **Downloads** → **Nutanix Kubernetes Platform (NKP)**
3. Download **NKP for Linux** (nkp_v2.16.x_linux_amd64.tar.gz)

```bash
# Download NKP (replace URL with your portal download link)
curl -Lo nkp_v2.16.1_linux_amd64.tar.gz "<YOUR_NUTANIX_PORTAL_DOWNLOAD_URL>"

# Extract the archive
tar -zxvf nkp_v2.16.1_linux_amd64.tar.gz

# Move NKP binary to PATH
sudo mv nkp /usr/local/bin/

# Verify installation
nkp version
```

Expected output:
```
diagnose: v0.10.x
imagebuilder: v0.13.x
kommander: v2.16.x
konvoy: v2.16.x
mindthegap: v1.13.x
nkp: v2.16.x
```

### 2.7 Generate SSH Keys

```bash
# Generate SSH key pair (if not already existing)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""

# Verify keys exist
ls -la ~/.ssh/
# Should show: id_rsa (private) and id_rsa.pub (public)
```

---

## 3. Create the Base VM Template in vSphere

### 3.1 Download Ubuntu 22.04 Cloud Image

Download the Ubuntu 22.04 OVA cloud image:

```bash
# Download Ubuntu 22.04 cloud image OVA
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.ova
```

### 3.2 Import OVA to vSphere

**Option A: Using vSphere Web Client**

1. Log in to vCenter Web Client
2. Right-click on your cluster/resource pool → **Deploy OVF Template**
3. Select the downloaded OVA file
4. Follow the wizard:
   - Name: `ubuntu-2204-base-template`
   - Select datacenter and folder
   - Select compute resource
   - Select storage (thin provisioning recommended)
   - Select network
5. Review and finish deployment
6. **Do NOT power on the VM yet**

**Option B: Using govc CLI**

```bash
# Install govc
curl -L -o govc.tar.gz https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz
tar -zxvf govc.tar.gz govc
sudo mv govc /usr/local/bin/
rm govc.tar.gz

# Set vSphere environment variables
export GOVC_URL="https://vcenter.example.com/sdk"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD="your-password"
export GOVC_INSECURE=true  # Only if using self-signed certs

# Import OVA
govc import.ova -folder=Templates -name=ubuntu-2204-base-template jammy-server-cloudimg-amd64.ova
```

### 3.3 Configure the Base Template

1. In vCenter, right-click the imported VM → **Edit Settings**
2. Adjust resources as needed:
   - **CPU:** 4 vCPU
   - **Memory:** 16 GB
   - **Disk:** 80 GB (expand if needed)
3. Under **VM Options** → **Boot Options**:
   - Ensure BIOS or EFI is set appropriately
4. Under **vApp Options** (if available):
   - Enable **OVF environment**
   - This is required for cloud-init to work properly
5. **Convert to Template:**
   - Right-click VM → **Template** → **Convert to Template**

### 3.4 Alternative: Create Base Template from ISO

If you prefer installing from scratch:

1. Create a new VM in vSphere:
   - **Guest OS:** Ubuntu Linux (64-bit)
   - **vCPU:** 4
   - **Memory:** 16 GB
   - **Disk:** 80 GB (no SWAP partition)
2. Attach Ubuntu 22.04 Server ISO
3. Boot and install with **Minimal Install**
4. Configure:
   - Network (DHCP or static)
   - Create a user (e.g., `ubuntu`)
   - Enable OpenSSH server
5. After installation, install cloud-init:

```bash
sudo apt update
sudo apt install -y cloud-init open-vm-tools
sudo systemctl enable cloud-init
```

6. Clean up for templating:

```bash
# Clean cloud-init state
sudo cloud-init clean

# Remove SSH host keys (will regenerate on first boot)
sudo rm -f /etc/ssh/ssh_host_*

# Clear machine-id
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id

# Clear logs
sudo truncate -s 0 /var/log/*.log

# Shutdown
sudo shutdown -h now
```

7. Convert to template in vCenter

---

## 4. Build the CAPI VM Template with KIB

Konvoy Image Builder (KIB) creates the Kubernetes-ready VM template from your base template.

### 4.1 Set vSphere Environment Variables

```bash
export VSPHERE_SERVER="vcenter.example.com"
export VSPHERE_USERNAME="administrator@vsphere.local"
export VSPHERE_PASSWORD="your-password"

# SSH credentials for the base template
export SSH_USERNAME="ubuntu"
export SSH_PASSWORD="your-template-password"  # Or use SSH_PRIVATE_KEY_FILE
# export SSH_PRIVATE_KEY_FILE="~/.ssh/id_rsa"
```

### 4.2 Create image.yaml Configuration

Create a file named `ubuntu-2204-image.yaml`:

```yaml
---
download_images: true
build_name: "ubuntu-2204"
packer_builder_type: "vsphere"
guestinfo_datasource_slug: "https://raw.githubusercontent.com/vmware/cloud-init-vmware-guestinfo"
guestinfo_datasource_ref: "v1.4.0"
guestinfo_datasource_script: "{{guestinfo_datasource_slug}}/{{guestinfo_datasource_ref}}/install.sh"

packer:
  cluster: "your-vsphere-cluster"
  datacenter: "your-datacenter"
  datastore: "your-datastore"
  folder: "Templates"
  insecure_connection: "true"  # Set to "false" if using valid certs
  network: "your-vm-network"
  resource_pool: "your-resource-pool"
  template: "ubuntu-2204-base-template"  # Your base template name
  vsphere_guest_os_type: "ubuntu64Guest"
  guest_os_type: "ubuntu2204-64"
  
  # Goss validation parameters
  distribution: "ubuntu"
  distribution_version: "22.04"
```

### 4.3 Build the CAPI Template

```bash
# Navigate to where you extracted NKP
cd /path/to/nkp-extracted

# Build the image
konvoy-image build --config ubuntu-2204-image.yaml

# For air-gapped environments, add overrides:
# konvoy-image build --config ubuntu-2204-image.yaml --overrides overrides/offline.yaml
```

This process takes 15-30 minutes. When complete, you'll see output with the template name (artifact_id).

### 4.4 Rename the Template (Recommended)

In vCenter, rename the newly created template to a descriptive name:

```
dkp-2.16.1-k8s-1.33-ubuntu-2204
```

---

## 5. Create the Management Cluster

### 5.1 Set Environment Variables

```bash
# Cluster name (lowercase, no special chars except . and -)
export CLUSTER_NAME="nkp-mgmt-lab"

# vSphere credentials
export VSPHERE_SERVER="vcenter.example.com"
export VSPHERE_USERNAME="administrator@vsphere.local"
export VSPHERE_PASSWORD="your-password"
```

### 5.2 Plan Your IP Addresses

Document your IP allocations:

| Purpose | IP Address |
|---------|------------|
| Control Plane VIP | 192.168.1.100 |
| Control Plane Node 1 | DHCP or 192.168.1.101 |
| Worker Node 1 | DHCP or 192.168.1.111 |
| Worker Node 2 | DHCP or 192.168.1.112 |
| MetalLB Range | 192.168.1.150-192.168.1.160 |

### 5.3 Create the Self-Managed Cluster

For a small lab with 1 control plane and 2 workers:

```bash
nkp create cluster vsphere \
  --cluster-name ${CLUSTER_NAME} \
  --server ${VSPHERE_SERVER} \
  --data-center "your-datacenter" \
  --data-store "your-datastore" \
  --network "your-vm-network" \
  --resource-pool "your-resource-pool" \
  --folder "NKP-VMs" \
  --vm-template "dkp-2.16.1-k8s-1.33-ubuntu-2204" \
  --control-plane-endpoint-host 192.168.1.100 \
  --control-plane-endpoint-port 6443 \
  --virtual-ip-interface "ens192" \
  --ssh-public-key-file ~/.ssh/id_rsa.pub \
  --ssh-username ubuntu \
  --control-plane-replicas 1 \
  --control-plane-cpus 4 \
  --control-plane-memory 16 \
  --control-plane-disk-size 80 \
  --worker-replicas 2 \
  --worker-cpus 8 \
  --worker-memory 32 \
  --worker-disk-size 80 \
  --self-managed
```

> **Note:** Replace `ens192` with your actual network interface name (check with `ip a` on a VM).

### 5.4 For Production (3 Control Plane Nodes)

```bash
nkp create cluster vsphere \
  --cluster-name ${CLUSTER_NAME} \
  --server ${VSPHERE_SERVER} \
  --data-center "your-datacenter" \
  --data-store "your-datastore" \
  --network "your-vm-network" \
  --resource-pool "your-resource-pool" \
  --folder "NKP-VMs" \
  --vm-template "dkp-2.16.1-k8s-1.33-ubuntu-2204" \
  --control-plane-endpoint-host 192.168.1.100 \
  --control-plane-endpoint-port 6443 \
  --virtual-ip-interface "ens192" \
  --ssh-public-key-file ~/.ssh/id_rsa.pub \
  --ssh-username ubuntu \
  --control-plane-replicas 3 \
  --control-plane-cpus 4 \
  --control-plane-memory 16 \
  --control-plane-disk-size 80 \
  --worker-replicas 4 \
  --worker-cpus 8 \
  --worker-memory 32 \
  --worker-disk-size 80 \
  --self-managed
```

### 5.5 Using Docker Hub Credentials (Avoid Rate Limits)

Add these flags to avoid Docker Hub rate limiting:

```bash
  --registry-mirror-url https://registry-1.docker.io \
  --registry-mirror-username your-dockerhub-username \
  --registry-mirror-password your-dockerhub-password
```

### 5.6 Monitor Cluster Creation

The cluster creation takes 20-40 minutes. You can monitor progress:

```bash
# Watch the bootstrap cluster logs
kubectl --kubeconfig=<bootstrap-kubeconfig> get clusters -A -w

# Check VM creation in vCenter Web Client
```

### 5.7 Verify Cluster Creation

```bash
# Get the kubeconfig
export KUBECONFIG="${CLUSTER_NAME}.conf"

# Check nodes
kubectl get nodes

# Check all pods
kubectl get pods -A

# Check cluster status
kubectl get clusters -A
```

---

## 6. Access the NKP Dashboard

### 6.1 Get Dashboard Credentials

```bash
nkp get dashboard --kubeconfig=${CLUSTER_NAME}.conf
```

This outputs:
- Dashboard URL (e.g., `https://192.168.1.100:8443`)
- Username
- Password

### 6.2 Access the Dashboard

1. Open the Dashboard URL in your browser
2. Accept the self-signed certificate warning
3. Log in with the provided credentials
4. You should see your management cluster overview

---

## 7. Create a Workload Cluster (Optional)

For lab environments, you can deploy applications directly to the management cluster. For production-like setups, create a separate workload cluster.

### 7.1 Using the NKP Dashboard

1. Log in to the NKP Dashboard
2. Click **Clusters** → **+ Add Cluster** → **Create New Cluster**
3. Fill in the configuration:
   - Workspace: Default
   - Cluster Name: `nkp-workload-lab`
   - SSH Public Key: Paste your public key
4. Configure Control Plane:
   - vSphere settings (datacenter, datastore, network)
   - OS Image: Select your Ubuntu 22.04 template
   - Control Plane Endpoint IP
   - Node count (1 for lab, 3 for HA)
5. Configure Worker Pool:
   - Resource specifications
   - Node count
   - Enable autoscaling (optional)
6. Configure Storage and Networking
7. Click **Create**

### 7.2 Using CLI

```bash
export WORKLOAD_CLUSTER_NAME="nkp-workload-lab"

nkp create cluster vsphere \
  --cluster-name ${WORKLOAD_CLUSTER_NAME} \
  --kubeconfig=${CLUSTER_NAME}.conf \
  --server ${VSPHERE_SERVER} \
  --data-center "your-datacenter" \
  --data-store "your-datastore" \
  --network "your-vm-network" \
  --resource-pool "your-resource-pool" \
  --folder "NKP-VMs" \
  --vm-template "dkp-2.16.1-k8s-1.33-ubuntu-2204" \
  --control-plane-endpoint-host 192.168.1.200 \
  --control-plane-endpoint-port 6443 \
  --virtual-ip-interface "ens192" \
  --ssh-public-key-file ~/.ssh/id_rsa.pub \
  --ssh-username ubuntu \
  --control-plane-replicas 1 \
  --worker-replicas 2
```

### 7.3 Get Workload Cluster Kubeconfig

```bash
# From dashboard: Actions → Download kubeconfig

# Or using CLI:
kubectl --kubeconfig=${CLUSTER_NAME}.conf get secret ${WORKLOAD_CLUSTER_NAME}-kubeconfig \
  -n default -o jsonpath='{.data.value}' | base64 -d > ${WORKLOAD_CLUSTER_NAME}.conf
```

---

## 8. Troubleshooting

### 8.1 Common Issues

**Bootstrap cluster fails to start:**
```bash
# Check Docker is running
sudo systemctl status docker

# Check for port conflicts
netstat -tlnp | grep 6443
```

**VM template not found:**
- Verify the template name matches exactly
- Check the folder path in vSphere

**Control Plane VIP not accessible:**
- Ensure the VIP is in the same L2 network as control plane nodes
- Check firewall rules
- Verify the virtual-ip-interface name is correct

**Cluster creation timeout:**
```bash
# Check CAPI resources
kubectl --kubeconfig=<bootstrap-kubeconfig> get machines -A
kubectl --kubeconfig=<bootstrap-kubeconfig> describe machine <machine-name> -n <namespace>

# Check vSphere events for VM provisioning errors
```

### 8.2 Useful Commands

```bash
# Delete a cluster
nkp delete cluster --cluster-name ${CLUSTER_NAME}

# Delete bootstrap cluster
nkp delete bootstrap

# Check NKP version
nkp version

# Dry run (preview what will be created)
nkp create cluster vsphere ... --dry-run -o yaml
```

### 8.3 Log Locations

- Bootstrap cluster logs: Check Docker containers
- CAPI controller logs: `kubectl logs -n capi-system deployment/capi-controller-manager`
- vSphere provider logs: `kubectl logs -n capv-system deployment/capv-controller-manager`

---

## Quick Reference

### Minimum Lab Cluster Command

```bash
export CLUSTER_NAME="nkp-lab"
export VSPHERE_SERVER="vcenter.example.com"
export VSPHERE_USERNAME="administrator@vsphere.local"
export VSPHERE_PASSWORD="your-password"

nkp create cluster vsphere \
  --cluster-name ${CLUSTER_NAME} \
  --server ${VSPHERE_SERVER} \
  --data-center "Datacenter" \
  --data-store "datastore1" \
  --network "VM Network" \
  --resource-pool "Resources" \
  --folder "" \
  --vm-template "dkp-2.16.1-k8s-1.33-ubuntu-2204" \
  --control-plane-endpoint-host 192.168.1.100 \
  --virtual-ip-interface "ens192" \
  --ssh-public-key-file ~/.ssh/id_rsa.pub \
  --ssh-username ubuntu \
  --control-plane-replicas 1 \
  --worker-replicas 2 \
  --self-managed
```

---

## References

- [NKP 2.16 Documentation](https://docs.d2iq.com/dkp/2.16/)
- [NKP 2.16 Features and Enhancements](https://docs.d2iq.com/dkp/2.16/nkp-2-16-0-features-and-enhancements)
- [Nutanix Portal](https://portal.nutanix.com)
- [vSphere Prerequisites](https://portal.nutanix.com/page/documents/details?targetId=Nutanix-Kubernetes-Platform-v2_16:top-vsphere-prerequisites-c.html)
- [nkp create cluster vsphere Reference](https://docs.d2iq.com/dkp/2.8/nkp-create-cluster-vsphere)

---

*Guide created: April 2026*
*NKP Version: 2.16.x*
*Target OS: Ubuntu 22.04 LTS*
