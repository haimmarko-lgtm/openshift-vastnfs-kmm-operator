# VAST NFS KMM Operator Discussion

A conversation about deploying VAST NFS kernel modules on OpenShift, Nutanix, and vanilla Kubernetes.

---

## Question 1: Understanding the VAST NFS KMM Operator

**User:** I want to understand what this repo exactly doing and how it can help me to deploy vnfs driver on OpenShift. I'm not Kubernetes expert. I want to understand how it integrates with KMM and what is the role of KMM. Also to know how I can install kernel driver on hardened environment like OpenShift without root access.

https://github.com/vast-data/openshift-vastnfs-kmm-operator

---

## Answer 1: Understanding the VAST NFS KMM Operator for OpenShift

### What Does This Repository Do?

This repository automates the deployment of **VAST NFS kernel modules** on OpenShift clusters. Here's what that means in simpler terms:

### The Problem It Solves

**VAST NFS** is a high-performance NFS (Network File System) client that VAST Data provides. It's a modified/enhanced version of the standard Linux NFS stack with:
- Backported features from newer Linux kernels (5.15.x LTS)
- Multipath support for better performance and redundancy
- Nvidia GDS (GPUDirect Storage) integration for AI/ML workloads
- Various performance optimizations

To use VAST NFS, you need to install **kernel modules** on your Linux nodes. Kernel modules are pieces of code that extend the Linux kernel's functionality - think of them like plugins for your operating system's core.

### The Challenge with OpenShift

OpenShift is a "hardened" Kubernetes platform, meaning:
- You don't have direct root/SSH access to worker nodes
- Nodes run an immutable operating system (RHCOS - Red Hat CoreOS)
- You can't just SSH in and run `make install` like on a regular Linux server
- Security policies restrict what you can do

**This is where KMM comes in.**

---

## What is KMM (Kernel Module Management)?

**KMM** is an OpenShift/Kubernetes operator that solves the problem of installing kernel modules in a containerized, declarative way.

### How KMM Works (Simplified)

```
┌─────────────────────────────────────────────────────────────────┐
│                        OpenShift Cluster                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. You apply a "Module" custom resource (YAML file)           │
│                          ↓                                       │
│   2. KMM Operator sees this and:                                │
│      - Builds the kernel module in a container                  │
│      - Signs it (if secure boot is enabled)                     │
│      - Creates a container image with the module                │
│                          ↓                                       │
│   3. KMM creates a DaemonSet that runs on every matching node   │
│                          ↓                                       │
│   4. On each node, a privileged pod:                            │
│      - Downloads the container image                            │
│      - Runs 'modprobe' to load the kernel module                │
│                          ↓                                       │
│   5. VAST NFS modules are now active on all nodes!              │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Key KMM Concepts

| Concept | What It Means |
|---------|---------------|
| **Module CR** | A Kubernetes custom resource that describes what kernel module to build/load |
| **DaemonSet** | Ensures the module runs on every node (or nodes matching certain criteria) |
| **Build Pod** | A temporary pod that compiles the kernel module |
| **Driver Container** | A container image containing the compiled module |

---

## How This Repo Integrates with KMM

The repository provides:

1. **Kustomize manifests** (`k8s/` folder) - YAML files that define:
   - The namespace (`vastnfs-kmm`)
   - The KMM Module resource (tells KMM what to build)
   - ConfigMaps with build scripts
   - ServiceAccounts and permissions

2. **Build scripts** (`scripts/` folder) - Shell scripts that:
   - Download VAST NFS source code
   - Compile the kernel modules
   - Handle module loading/unloading

3. **Makefile** - Simple commands that orchestrate everything:
   ```bash
   make install      # Deploy VAST NFS
   make verify       # Check if it worked
   make uninstall    # Remove everything
   ```

---

## How Kernel Drivers Get Installed Without Root Access

This is the clever part. Here's how it works:

### The Container Privilege Model

```
Normal Container:
┌────────────────────┐
│  Limited access    │
│  No kernel access  │
│  Isolated          │
└────────────────────┘

Privileged Container (used by KMM):
┌────────────────────┐
│  Full host access  │  ← Can load kernel modules
│  Host PID/network  │  ← Sees real system
│  /host mounted     │  ← Access to node filesystem
└────────────────────┘
```

### How It Actually Happens

1. **KMM creates a privileged DaemonSet pod** on each node
2. **The pod runs as a "super-privileged" container** that has:
   - `privileged: true` security context
   - Access to the host's filesystem via volume mounts
   - The `SYS_MODULE` capability (permission to load kernel modules)
3. **Inside this container**, it runs commands like:
   ```bash
   modprobe sunrpc    # Load the VAST NFS modules
   modprobe nfs
   ```
4. **These commands affect the actual host kernel**, not the container

### Why This Is Secure

- Only cluster admins can deploy KMM modules (RBAC controls)
- KMM is a Red Hat-supported operator with security reviews
- Modules must be signed for Secure Boot environments
- Everything is audited and declarative (GitOps friendly)

---

## Secure Boot Environments

OpenShift can run with **Secure Boot** enabled, which means:
- Only signed kernel modules can be loaded
- This prevents malicious kernel code

The repository handles this with:

```bash
# Option 1: Auto-generate signing keys
make install-secure-boot

# Option 2: Use your organization's existing keys
export PRIVATE_KEY_FILE=/path/to/private.key
export PUBLIC_CERT_FILE=/path/to/public.crt
make install-secure-boot-with-keys
```

KMM will then:
1. Build the module
2. Sign it with the provided keys
3. Enroll the certificate in the node's MOK (Machine Owner Key) database
4. Load the signed module

---

## Quick Start Summary

If you want to deploy VAST NFS on OpenShift:

```bash
# 1. Clone the repo
git clone https://github.com/vast-data/openshift-vastnfs-kmm-operator
cd openshift-vastnfs-kmm-operator

# 2. Make sure KMM operator is installed in your cluster
#    (Usually done by cluster admin via OperatorHub)

# 3. Deploy VAST NFS
make install

# 4. Wait 1-2 minutes, then verify
make verify

# 5. Now you can mount VAST NFS filesystems!
```

---

## Key Takeaways

| Question | Answer |
|----------|--------|
| **What is this repo?** | Automation to deploy VAST NFS kernel modules on OpenShift |
| **What is KMM?** | An operator that manages kernel modules in a Kubernetes-native way |
| **How does it work without root?** | KMM uses privileged containers that can access the host kernel |
| **Is it secure?** | Yes - RBAC controls who can deploy modules, and Secure Boot signing is supported |
| **Do I need to be a Kubernetes expert?** | No - `make install` handles most complexity |

---

## Question 2: Vanilla Linux Installation

**User:** How can I achieve the same functionality on vanilla Linux without KMM?

---

## Answer 2: Installing VAST NFS on Vanilla Linux (Without KMM)

On regular Linux systems, it's much simpler because you have **direct root access**. KMM exists specifically to solve the problem of not having that access in containerized environments like OpenShift.

### The Traditional Approach

On vanilla Linux, you simply:

```bash
# 1. Download the VAST NFS package
wget https://vast-nfs.s3.amazonaws.com/vast-nfs-4.0.35.tar.gz

# 2. Extract it
tar -xzf vast-nfs-4.0.35.tar.gz
cd vast-nfs-4.0.35

# 3. Build the kernel modules
make

# 4. Install them
sudo make install

# 5. Load the modules
sudo modprobe sunrpc
sudo modprobe nfs
```

That's it. No operators, no containers, no Kubernetes complexity.

---

### Comparison: Vanilla Linux vs OpenShift

| Aspect | Vanilla Linux | OpenShift (with KMM) |
|--------|---------------|----------------------|
| **Root access** | Yes, direct SSH | No, nodes are immutable |
| **Installation method** | `make install` | Kubernetes manifests |
| **Module loading** | `modprobe` directly | Privileged container runs `modprobe` |
| **Multi-node deployment** | Manual (or Ansible/scripts) | Automatic via DaemonSet |
| **Upgrades** | Manual on each node | Automatic rollout |
| **Complexity** | Low | Higher (but necessary) |

---

### Detailed Steps for Vanilla Linux

#### Prerequisites

```bash
# Install build dependencies (RHEL/CentOS/Rocky)
sudo dnf install -y kernel-devel kernel-headers gcc make

# Or for Ubuntu/Debian
sudo apt install -y linux-headers-$(uname -r) build-essential
```

#### Installation

```bash
# Download VAST NFS (check for latest version)
VASTNFS_VERSION="4.0.35"
wget https://vast-nfs.s3.amazonaws.com/vast-nfs-${VASTNFS_VERSION}.tar.gz

# Extract
tar -xzf vast-nfs-${VASTNFS_VERSION}.tar.gz
cd vast-nfs-${VASTNFS_VERSION}

# Build for your current kernel
make

# Install modules to /lib/modules/$(uname -r)/
sudo make install

# Update module dependencies
sudo depmod -a

# Load the modules
sudo modprobe sunrpc
sudo modprobe nfs
sudo modprobe nfsv4
```

#### Verify Installation

```bash
# Check if modules are loaded
lsmod | grep -E "(sunrpc|nfs)"

# Check VAST NFS version
cat /sys/module/sunrpc/parameters/nfs_bundle_version

# Should output something like: 4.0.35
```

#### Make It Persistent (Survive Reboots)

```bash
# Create a module load configuration
echo -e "sunrpc\nnfs\nnfsv4" | sudo tee /etc/modules-load.d/vastnfs.conf
```

---

### Multi-Node Deployment on Vanilla Linux

If you have multiple Linux servers, you can automate with:

#### Option 1: Simple Bash Loop

```bash
NODES="node1 node2 node3"
for node in $NODES; do
    ssh root@$node "
        wget -q https://vast-nfs.s3.amazonaws.com/vast-nfs-4.0.35.tar.gz
        tar -xzf vast-nfs-4.0.35.tar.gz
        cd vast-nfs-4.0.35 && make && make install
        modprobe sunrpc && modprobe nfs
    "
done
```

#### Option 2: Ansible Playbook

```yaml
# vastnfs.yml
- hosts: all
  become: yes
  vars:
    vastnfs_version: "4.0.35"
  
  tasks:
    - name: Install build dependencies
      package:
        name:
          - kernel-devel
          - kernel-headers
          - gcc
          - make
        state: present

    - name: Download VAST NFS
      get_url:
        url: "https://vast-nfs.s3.amazonaws.com/vast-nfs-{{ vastnfs_version }}.tar.gz"
        dest: "/tmp/vast-nfs-{{ vastnfs_version }}.tar.gz"

    - name: Extract VAST NFS
      unarchive:
        src: "/tmp/vast-nfs-{{ vastnfs_version }}.tar.gz"
        dest: /tmp
        remote_src: yes

    - name: Build and install VAST NFS
      shell: |
        cd /tmp/vast-nfs-{{ vastnfs_version }}
        make && make install
      args:
        creates: /lib/modules/{{ ansible_kernel }}/extra/sunrpc.ko

    - name: Load kernel modules
      modprobe:
        name: "{{ item }}"
        state: present
      loop:
        - sunrpc
        - nfs
        - nfsv4

    - name: Ensure modules load on boot
      copy:
        content: |
          sunrpc
          nfs
          nfsv4
        dest: /etc/modules-load.d/vastnfs.conf
```

Run with:
```bash
ansible-playbook -i inventory.txt vastnfs.yml
```

---

### Why KMM Exists (The OpenShift Problem)

To understand why KMM is needed, consider what happens on OpenShift:

```
Vanilla Linux:
┌─────────────────────────────────┐
│  You (admin)                    │
│       ↓                         │
│  SSH → root@node                │
│       ↓                         │
│  make install && modprobe nfs   │
│       ↓                         │
│  ✓ Done!                        │
└─────────────────────────────────┘

OpenShift:
┌─────────────────────────────────┐
│  You (admin)                    │
│       ↓                         │
│  No SSH access ❌                │
│  Immutable OS ❌                 │
│  No root ❌                      │
│                                 │
│  How do you install modules?    │
│       ↓                         │
│  KMM Operator (workaround)      │
│       ↓                         │
│  Privileged container → modprobe│
│       ↓                         │
│  ✓ Done!                        │
└─────────────────────────────────┘
```

---

### Summary

| Environment | Method | Complexity |
|-------------|--------|------------|
| **Single Linux server** | `make && make install && modprobe` | Very simple |
| **Multiple Linux servers** | Ansible/scripts | Simple |
| **Kubernetes (vanilla)** | Privileged DaemonSet | Medium |
| **OpenShift** | KMM Operator | Higher (but automated) |

---

## Question 3: Hardened OS Without Root Access

**User:** I don't have root access to the system. It's another hardened OS used by Nutanix that lacks the KMM functionality operator.

---

## Answer 3: Installing Kernel Modules on Hardened Systems Without Root Access

This is a challenging situation. Let me help you understand your options.

### The Core Problem

On hardened/immutable systems without root access, you fundamentally **cannot** install kernel modules through normal means. The security model explicitly prevents this.

```
┌─────────────────────────────────────────────────────────┐
│              Hardened OS Security Model                  │
├─────────────────────────────────────────────────────────┤
│                                                          │
│   Kernel Space (ring 0)                                 │
│   ┌─────────────────────────────────────────────────┐   │
│   │  Kernel modules live here                       │   │
│   │  Requires: CAP_SYS_MODULE + root + kernel trust │   │
│   │                                                 │   │
│   │  🔒 LOCKED on hardened systems                  │   │
│   └─────────────────────────────────────────────────┘   │
│                         ▲                               │
│                         │ BLOCKED                       │
│                         │                               │
│   User Space                                            │
│   ┌─────────────────────────────────────────────────┐   │
│   │  Your applications run here                     │   │
│   │  No kernel access without root                  │   │
│   └─────────────────────────────────────────────────┘   │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

---

### What Type of Nutanix Environment Are You Using?

The solution depends on your specific setup:

| Environment | Can You Install Kernel Modules? |
|-------------|--------------------------------|
| **Nutanix AHV (hypervisor layer)** | No - completely locked down |
| **VMs running ON Nutanix** | Yes, if you have root inside the VM |
| **Nutanix Kubernetes Engine (NKE)** | Possible via privileged containers |
| **Nutanix Files/Objects** | No - appliance-based |

---

### Your Options

#### Option 1: Request the Module Be Pre-Installed (Best for AHV)

If you need VAST NFS on the Nutanix hypervisor layer itself:

1. **Work with Nutanix Support** - Ask if VAST NFS can be included in a custom AHV image
2. **Work with VAST Data Support** - They may have a partnership or certified integration path
3. **Use Nutanix Files** as an alternative NFS solution (built-in)

#### Option 2: Use a VM Where You Have Root Access

If your workloads run in VMs on Nutanix:

```
┌─────────────────────────────────────────────┐
│           Nutanix Cluster                    │
│  ┌───────────────────────────────────────┐  │
│  │  AHV Hypervisor (locked down)         │  │
│  │                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐    │  │
│  │  │   VM 1      │  │   VM 2      │    │  │
│  │  │ (your VM)   │  │ (your VM)   │    │  │
│  │  │             │  │             │    │  │
│  │  │ ✓ Root OK   │  │ ✓ Root OK   │    │  │
│  │  │ Install     │  │ Install     │    │  │
│  │  │ VAST NFS    │  │ VAST NFS    │    │  │
│  │  │ here!       │  │ here!       │    │  │
│  │  └─────────────┘  └─────────────┘    │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

Inside your VMs, you typically have full control and can install kernel modules normally.

#### Option 3: DIY "KMM-like" Solution for NKE

If you're running **Nutanix Kubernetes Engine (NKE)**, you can create a privileged DaemonSet that does what KMM does - without needing the KMM operator itself.

Here's a simplified version:

```yaml
# vastnfs-daemonset.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vastnfs
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vastnfs-loader
  namespace: vastnfs
spec:
  selector:
    matchLabels:
      app: vastnfs-loader
  template:
    metadata:
      labels:
        app: vastnfs-loader
    spec:
      hostPID: true
      hostNetwork: true
      containers:
      - name: vastnfs
        image: registry.example.com/vastnfs-driver:4.0.35  # Pre-built image
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-modules
          mountPath: /lib/modules
        - name: host-usr
          mountPath: /host/usr
          readOnly: true
        command:
        - /bin/sh
        - -c
        - |
          # Copy modules to host
          cp -r /vastnfs-modules/* /lib/modules/$(uname -r)/extra/
          depmod -a
          modprobe sunrpc
          modprobe nfs
          modprobe nfsv4
          # Keep container running
          sleep infinity
      volumes:
      - name: host-modules
        hostPath:
          path: /lib/modules
      - name: host-usr
        hostPath:
          path: /usr
      tolerations:
      - operator: Exists  # Run on all nodes
```

**But this requires:**
- Kubernetes cluster admin access to create privileged workloads
- A container registry to store the pre-built driver image
- The cluster must allow privileged containers (may be blocked by policy)

#### Option 4: User-Space NFS (No Kernel Module Required)

If kernel modules are truly impossible, consider **user-space NFS implementations**:

| Solution | Description |
|----------|-------------|
| **NFS-Ganesha** | User-space NFS server (doesn't help for client) |
| **FUSE-based NFS** | User-space NFS client via FUSE |
| **s3fs / goofys** | If VAST supports S3 protocol |

However, FUSE-based solutions have **significant performance penalties** compared to kernel NFS.

---

### The Hard Truth

If you have **no root access** and **no privileged container capability** and **no way to request pre-installed modules**, then installing kernel modules is **not possible by design**. The security model is working as intended.

Your realistic options become:

1. **Escalate to someone with admin access** (Nutanix admin, IT team)
2. **Use a different storage protocol** that doesn't require kernel modules (S3, iSCSI if already configured, etc.)
3. **Use VMs where you do have root** instead of the hardened host OS
4. **Work with VAST and Nutanix support** for a certified integration path

---

## Question 4: Building the Container Image

**User:** For option 3, how can I build the image? What do I need exactly?

---

## Answer 4: Building a VAST NFS Driver Container Image

This guide walks you through building a container image that contains pre-compiled VAST NFS kernel modules for deployment via a privileged DaemonSet.

### Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      Build Process                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Build Machine (with matching kernel)                        │
│     ┌─────────────────────────────────────────┐                 │
│     │  - Same OS/kernel as target nodes       │                 │
│     │  - Root access (for building)           │                 │
│     │  - Docker/Podman installed              │                 │
│     └─────────────────────────────────────────┘                 │
│                      ↓                                          │
│  2. Compile VAST NFS modules                                    │
│                      ↓                                          │
│  3. Package into container image                                │
│                      ↓                                          │
│  4. Push to container registry                                  │
│                      ↓                                          │
│  5. Deploy DaemonSet on target cluster                          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Prerequisites

#### What You Need

| Requirement | Description |
|-------------|-------------|
| **Build machine** | A Linux system where you DO have root access |
| **Matching kernel** | Must match the kernel version on your Nutanix/target nodes |
| **Container runtime** | Docker or Podman |
| **Container registry** | Docker Hub, Quay.io, Harbor, or private registry |
| **VAST NFS source** | Download from VAST or S3 bucket |

#### Critical: Kernel Version Must Match

Kernel modules are **compiled for a specific kernel version**. You must build on a system with the **exact same kernel** as your target nodes.

```bash
# On your target nodes (or find out from admin), check:
uname -r
# Example output: 5.14.0-284.30.1.el9_2.x86_64

# Your build machine must have the same kernel version
# OR at minimum, the same kernel-devel/headers package
```

---

### Step-by-Step Guide

#### Step 1: Set Up Build Machine

You need a machine with:
- Same OS distribution as target (e.g., RHEL 9, Rocky 9, Ubuntu 22.04)
- Root access
- Docker or Podman

```bash
# Example: Spin up a VM or use a dev machine with matching OS
# Install container tools
sudo dnf install -y podman   # RHEL/Rocky/CentOS
# OR
sudo apt install -y docker.io  # Ubuntu/Debian
```

#### Step 2: Create the Build Directory Structure

```bash
mkdir -p vastnfs-driver-image/{modules,scripts}
cd vastnfs-driver-image
```

#### Step 3: Create the Dockerfile

```dockerfile
# Dockerfile
# Multi-stage build: compile modules, then create minimal runtime image

#############################################
# Stage 1: Build the kernel modules
#############################################
FROM registry.access.redhat.com/ubi9/ubi:latest AS builder

# Arguments for customization
ARG VASTNFS_VERSION=4.0.35
ARG KERNEL_VERSION

# Install build dependencies
RUN dnf install -y \
    kernel-devel-${KERNEL_VERSION} \
    kernel-headers-${KERNEL_VERSION} \
    gcc \
    make \
    elfutils-libelf-devel \
    wget \
    tar \
    && dnf clean all

# Download and extract VAST NFS
WORKDIR /build
RUN wget -q https://vast-nfs.s3.amazonaws.com/vast-nfs-${VASTNFS_VERSION}.tar.gz \
    && tar -xzf vast-nfs-${VASTNFS_VERSION}.tar.gz \
    && rm vast-nfs-${VASTNFS_VERSION}.tar.gz

# Build the modules
WORKDIR /build/vast-nfs-${VASTNFS_VERSION}
RUN make KVER=${KERNEL_VERSION}

# Collect built modules
RUN mkdir -p /built-modules \
    && find . -name "*.ko" -exec cp {} /built-modules/ \;

#############################################
# Stage 2: Create runtime image
#############################################
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

ARG KERNEL_VERSION
ARG VASTNFS_VERSION=4.0.35

LABEL description="VAST NFS kernel modules for ${KERNEL_VERSION}"
LABEL vastnfs.version="${VASTNFS_VERSION}"
LABEL kernel.version="${KERNEL_VERSION}"

# Install minimal runtime tools
RUN microdnf install -y kmod util-linux && microdnf clean all

# Copy built modules from builder stage
COPY --from=builder /built-modules/*.ko /opt/vastnfs-modules/

# Copy loader script
COPY scripts/load-modules.sh /opt/scripts/load-modules.sh
RUN chmod +x /opt/scripts/load-modules.sh

# Set entrypoint
ENTRYPOINT ["/opt/scripts/load-modules.sh"]
```

#### Step 4: Create the Module Loader Script

```bash
#!/bin/bash
# scripts/load-modules.sh
set -e

KERNEL_VERSION=$(uname -r)
MODULE_DIR="/opt/vastnfs-modules"
HOST_MODULE_DIR="/lib/modules/${KERNEL_VERSION}/extra/vastnfs"

echo "=== VAST NFS Module Loader ==="
echo "Kernel version: ${KERNEL_VERSION}"
echo "Module source: ${MODULE_DIR}"
echo "Target directory: ${HOST_MODULE_DIR}"

# Function to check if module is loaded
is_module_loaded() {
    lsmod | grep -q "^$1 " 2>/dev/null
}

# Function to unload module if loaded (for upgrades)
unload_if_loaded() {
    local module=$1
    if is_module_loaded "$module"; then
        echo "Unloading existing module: $module"
        rmmod "$module" 2>/dev/null || true
    fi
}

# Create target directory on host
mkdir -p "${HOST_MODULE_DIR}"

# Copy modules to host filesystem
echo "Copying modules to host..."
cp -v ${MODULE_DIR}/*.ko "${HOST_MODULE_DIR}/"

# Update module dependencies
echo "Running depmod..."
depmod -a

# Unload existing modules (in reverse dependency order)
echo "Unloading any existing VAST NFS modules..."
for module in nfsv4 nfs nfs_acl lockd sunrpc; do
    unload_if_loaded "$module"
done

# Load modules in correct order
echo "Loading VAST NFS modules..."
MODULES=(sunrpc lockd nfs_acl nfs nfsv4)

for module in "${MODULES[@]}"; do
    if [ -f "${HOST_MODULE_DIR}/${module}.ko" ]; then
        echo "Loading: ${module}"
        insmod "${HOST_MODULE_DIR}/${module}.ko" || modprobe "$module"
    else
        echo "Module ${module}.ko not found, trying modprobe..."
        modprobe "$module" || true
    fi
done

# Verify modules are loaded
echo ""
echo "=== Loaded NFS Modules ==="
lsmod | grep -E "(sunrpc|nfs|lockd)" || echo "Warning: No NFS modules found!"

# Check VAST NFS version
if [ -f /sys/module/sunrpc/parameters/nfs_bundle_version ]; then
    echo ""
    echo "VAST NFS Version: $(cat /sys/module/sunrpc/parameters/nfs_bundle_version)"
fi

echo ""
echo "=== Module loading complete ==="

# Keep container running (for DaemonSet)
echo "Entering sleep mode. Container will keep running..."
exec sleep infinity
```

Make it executable:
```bash
chmod +x scripts/load-modules.sh
```

#### Step 5: Build the Container Image

```bash
# First, get the kernel version from your target nodes
# Ask your admin or check documentation
TARGET_KERNEL="5.14.0-284.30.1.el9_2.x86_64"  # Example - use YOUR kernel version
VASTNFS_VERSION="4.0.35"
REGISTRY="your-registry.example.com"  # Your container registry

# Build the image
podman build \
    --build-arg KERNEL_VERSION=${TARGET_KERNEL} \
    --build-arg VASTNFS_VERSION=${VASTNFS_VERSION} \
    -t ${REGISTRY}/vastnfs-driver:${TARGET_KERNEL}-v${VASTNFS_VERSION} \
    .

# Or with Docker
docker build \
    --build-arg KERNEL_VERSION=${TARGET_KERNEL} \
    --build-arg VASTNFS_VERSION=${VASTNFS_VERSION} \
    -t ${REGISTRY}/vastnfs-driver:${TARGET_KERNEL}-v${VASTNFS_VERSION} \
    .
```

#### Step 6: Push to Container Registry

```bash
# Login to your registry
podman login ${REGISTRY}

# Push the image
podman push ${REGISTRY}/vastnfs-driver:${TARGET_KERNEL}-v${VASTNFS_VERSION}
```

#### Step 7: Create the Kubernetes DaemonSet

```yaml
# vastnfs-daemonset.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vastnfs
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vastnfs-loader
  namespace: vastnfs
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vastnfs-loader
  namespace: vastnfs
  labels:
    app: vastnfs-loader
spec:
  selector:
    matchLabels:
      app: vastnfs-loader
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: vastnfs-loader
    spec:
      serviceAccountName: vastnfs-loader
      hostPID: true
      hostNetwork: true
      nodeSelector:
        # Optional: only deploy to specific nodes
        # kubernetes.io/os: linux
      containers:
      - name: vastnfs-loader
        # UPDATE THIS with your image
        image: your-registry.example.com/vastnfs-driver:5.14.0-284.30.1.el9_2.x86_64-v4.0.35
        imagePullPolicy: Always
        securityContext:
          privileged: true
          capabilities:
            add:
              - SYS_MODULE
              - SYS_ADMIN
        volumeMounts:
        - name: lib-modules
          mountPath: /lib/modules
        - name: host-usr-src
          mountPath: /usr/src
          readOnly: true
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
      volumes:
      - name: lib-modules
        hostPath:
          path: /lib/modules
          type: Directory
      - name: host-usr-src
        hostPath:
          path: /usr/src
          type: DirectoryOrCreate
      tolerations:
      # Tolerate all taints to run on all nodes
      - operator: Exists
      terminationGracePeriodSeconds: 30
```

#### Step 8: Deploy to Kubernetes

```bash
# Apply the DaemonSet
kubectl apply -f vastnfs-daemonset.yaml

# Watch the rollout
kubectl -n vastnfs get pods -w

# Check logs
kubectl -n vastnfs logs -l app=vastnfs-loader
```

---

### Complete File Structure

```
vastnfs-driver-image/
├── Dockerfile
├── scripts/
│   └── load-modules.sh
└── vastnfs-daemonset.yaml
```

---

### Handling Multiple Kernel Versions

If your cluster has nodes with different kernel versions, you need to build multiple images:

```bash
# Build for each kernel version
for KERNEL in "5.14.0-284.30.1.el9_2.x86_64" "5.14.0-362.8.1.el9_3.x86_64"; do
    podman build \
        --build-arg KERNEL_VERSION=${KERNEL} \
        --build-arg VASTNFS_VERSION=4.0.35 \
        -t ${REGISTRY}/vastnfs-driver:${KERNEL}-v4.0.35 \
        .
    podman push ${REGISTRY}/vastnfs-driver:${KERNEL}-v4.0.35
done
```

Then create separate DaemonSets with node selectors, or use a more sophisticated approach with init containers that detect the kernel version.

---

### Troubleshooting

#### Build Fails: Kernel Headers Not Found

```bash
# Make sure kernel-devel matches exactly
dnf list available kernel-devel*
dnf install kernel-devel-$(uname -r)
```

#### Modules Won't Load: Version Mismatch

```
modprobe: ERROR: could not insert 'sunrpc': Invalid module format
```

This means the module was compiled for a different kernel. Rebuild with the correct `KERNEL_VERSION`.

#### Registry Access Issues

```bash
# Create image pull secret in Kubernetes
kubectl create secret docker-registry vastnfs-pull-secret \
    --docker-server=your-registry.example.com \
    --docker-username=YOUR_USER \
    --docker-password=YOUR_PASSWORD \
    -n vastnfs

# Add to DaemonSet spec:
# spec:
#   imagePullSecrets:
#   - name: vastnfs-pull-secret
```

#### Privileged Containers Blocked

If your cluster has Pod Security Policies or Pod Security Standards that block privileged containers, you'll need cluster admin to create an exception for the `vastnfs` namespace.

---

### Summary Checklist

- [ ] Identify target kernel version(s) from your Nutanix nodes
- [ ] Set up build machine with matching kernel
- [ ] Create Dockerfile and loader script
- [ ] Build container image with correct kernel version
- [ ] Push to accessible container registry
- [ ] Create and apply DaemonSet YAML
- [ ] Verify modules are loaded on nodes

---

## Question 5: KMM for Vanilla Kubernetes

**User:** Is there KMM for vanilla Kubernetes?

---

## Answer 5: KMM for Vanilla Kubernetes

Yes, KMM (Kernel Module Management) is available for vanilla Kubernetes. It's not OpenShift-exclusive.

### KMM Versions

| Version | Platform | Repository |
|---------|----------|------------|
| **KMM (upstream)** | Vanilla Kubernetes | [kubernetes-sigs/kernel-module-management](https://github.com/kubernetes-sigs/kernel-module-management) |
| **KMM (OpenShift)** | OpenShift | Distributed via OperatorHub |

The upstream KMM is maintained under the **Kubernetes SIGs** (Special Interest Groups) organization, which means it's an official Kubernetes community project.

---

### Installing KMM on Vanilla Kubernetes

#### Option 1: Using Helm (Recommended)

```bash
# Add the KMM Helm repository
helm repo add kmm https://kubernetes-sigs.github.io/kernel-module-management/
helm repo update

# Install KMM
helm install kmm kmm/kernel-module-management --namespace kmm-system --create-namespace
```

#### Option 2: Using kubectl

```bash
# Install cert-manager first (KMM dependency)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

# Install KMM
kubectl apply -k https://github.com/kubernetes-sigs/kernel-module-management/config/default
```

#### Option 3: Build from Source

```bash
git clone https://github.com/kubernetes-sigs/kernel-module-management.git
cd kernel-module-management
make deploy
```

---

### Verify Installation

```bash
# Check KMM operator is running
kubectl get pods -n kmm-system

# Check CRDs are installed
kubectl get crd | grep kmm
# Should show:
# modules.kmm.sigs.x-k8s.io
# nodemodulesconfigs.kmm.sigs.x-k8s.io
# preflightvalidations.kmm.sigs.x-k8s.io
```

---

### Using KMM on Vanilla Kubernetes

Once installed, usage is nearly identical to OpenShift. Here's an example Module CR:

```yaml
apiVersion: kmm.sigs.x-k8s.io/v1beta1
kind: Module
metadata:
  name: vastnfs
  namespace: vastnfs-kmm
spec:
  moduleLoader:
    container:
      modprobe:
        moduleName: sunrpc
        dirName: /opt/lib/modules
        parameters:
          - nfs_bundle_version=4.0.35
      kernelMappings:
        - regexp: '^.*\.x86_64$'
          containerImage: your-registry.com/vastnfs:${KERNEL_FULL_VERSION}
          build:
            dockerfileConfigMap:
              name: vastnfs-dockerfile
  selector:
    node-role.kubernetes.io/worker: ""
```

---

### KMM Features on Vanilla Kubernetes

| Feature | Supported |
|---------|-----------|
| In-cluster module building | ✅ Yes |
| Pre-built module images | ✅ Yes |
| Module signing | ✅ Yes |
| Secure Boot support | ✅ Yes |
| Node selector/affinity | ✅ Yes |
| Ordered module loading | ✅ Yes |
| Module unloading | ✅ Yes |
| Preflight validation | ✅ Yes |

---

### Comparison: DIY DaemonSet vs KMM

| Aspect | DIY DaemonSet | KMM |
|--------|---------------|-----|
| **Setup complexity** | Lower initial | Higher initial |
| **Build automation** | Manual | Automatic in-cluster |
| **Multi-kernel support** | Manual per kernel | Automatic via regexp |
| **Module ordering** | Manual scripting | Declarative |
| **Upgrades** | Manual rollout | Automatic |
| **Uninstall cleanup** | Manual | Automatic |
| **Secure Boot** | Manual signing | Built-in support |

---

### When to Use KMM vs DIY

**Use KMM when:**
- You have multiple kernel versions across nodes
- You want automatic rebuilds when kernels update
- You need proper module lifecycle management
- You want a declarative, GitOps-friendly approach

**Use DIY DaemonSet when:**
- KMM cannot be installed (cluster policy restrictions)
- You have a single kernel version
- You want simpler, more transparent control
- Quick proof-of-concept

---

### Quick Start with KMM on Vanilla Kubernetes

```bash
# 1. Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

# 2. Install KMM
helm repo add kmm https://kubernetes-sigs.github.io/kernel-module-management/
helm repo update
helm install kmm kmm/kernel-module-management -n kmm-system --create-namespace

# 3. Wait for KMM to be ready
kubectl wait --for=condition=Available deployment --all -n kmm-system --timeout=300s

# 4. Now you can deploy Module CRs just like on OpenShift!
```

---

### Resources

- **GitHub**: https://github.com/kubernetes-sigs/kernel-module-management
- **Documentation**: https://kmm.sigs.k8s.io/
- **Helm Chart**: https://kubernetes-sigs.github.io/kernel-module-management/

---

## Question 6: Using KMM on Nutanix Kubernetes Engine (NKE)

**User:** Do you think I can use https://github.com/kubernetes-sigs/kernel-module-management and setup a solution like on OCP in NKE?

---

## Answer 6: Yes, You Can Use KMM on Nutanix Kubernetes Engine (NKE)

Based on the upstream KMM project, this is absolutely achievable. The upstream KMM is specifically designed for vanilla Kubernetes, and NKE is essentially vanilla Kubernetes managed by Nutanix.

### Feasibility Assessment

| Aspect | NKE Support | Notes |
|--------|-------------|-------|
| **KMM Installation** | ✅ Yes | Standard Kubernetes, no OpenShift dependencies |
| **Privileged Containers** | ✅ Usually | NKE typically allows privileged workloads |
| **In-cluster Builds** | ✅ Yes | KMM can build modules inside the cluster |
| **Container Registry** | ✅ Yes | Use Nutanix registry, Harbor, or external |
| **cert-manager** | ✅ Yes | Standard Kubernetes component |

### What You Need to Verify on NKE

Before proceeding, confirm these with your NKE admin:

```bash
# 1. Check if privileged containers are allowed
kubectl auth can-i create pods --as=system:serviceaccount:kmm-system:kmm-operator \
    --all-namespaces

# 2. Check Pod Security Standards/Policies
kubectl get psp  # Old method
kubectl get ns --show-labels | grep pod-security  # New method

# 3. Check kernel version on worker nodes
kubectl get nodes -o wide
kubectl debug node/<node-name> -- chroot /host uname -r
```

---

### Architecture on NKE

```
┌─────────────────────────────────────────────────────────────────┐
│                    Nutanix Kubernetes Engine                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  KMM Operator (kmm-system namespace)                    │    │
│  │  - Watches for Module CRs                               │    │
│  │  - Triggers builds                                      │    │
│  │  - Manages DaemonSets                                   │    │
│  └─────────────────────────────────────────────────────────┘    │
│                           ↓                                      │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  VAST NFS Module CR (vastnfs-kmm namespace)             │    │
│  │  - Defines how to build VAST NFS modules                │    │
│  │  - Specifies kernel mappings                            │    │
│  │  - Configures module loading                            │    │
│  └─────────────────────────────────────────────────────────┘    │
│                           ↓                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │  Worker 1    │  │  Worker 2    │  │  Worker 3    │          │
│  │  VAST NFS ✓  │  │  VAST NFS ✓  │  │  VAST NFS ✓  │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Step 1: Install cert-manager

```bash
# cert-manager is a KMM dependency
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.yaml

# Wait for it to be ready
kubectl -n cert-manager wait --for=condition=Available deployment \
    cert-manager \
    cert-manager-cainjector \
    cert-manager-webhook \
    --timeout=300s
```

### Step 2: Install KMM

```bash
# Install KMM from upstream
kubectl apply -k https://github.com/kubernetes-sigs/kernel-module-management/config/default

# Wait for KMM to be ready
kubectl -n kmm-operator-system wait --for=condition=Available deployment \
    kmm-operator-controller \
    --timeout=300s

# Verify CRDs are installed
kubectl get crd | grep kmm
```

### Step 3: Create the VAST NFS Namespace and ConfigMaps

```yaml
# 01-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vastnfs-kmm
  labels:
    # Allow privileged workloads (for Kubernetes 1.25+)
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

```yaml
# 02-dockerfile-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vastnfs-dockerfile
  namespace: vastnfs-kmm
data:
  Dockerfile: |
    ARG DTK_AUTO
    FROM ${DTK_AUTO} as builder
    
    ARG KERNEL_VERSION
    ARG VASTNFS_VERSION=4.0.35
    
    WORKDIR /build
    
    # Install build dependencies
    RUN dnf install -y wget tar make gcc elfutils-libelf-devel && dnf clean all
    
    # Download and build VAST NFS
    RUN wget -q https://vast-nfs.s3.amazonaws.com/vast-nfs-${VASTNFS_VERSION}.tar.gz \
        && tar -xzf vast-nfs-${VASTNFS_VERSION}.tar.gz \
        && cd vast-nfs-${VASTNFS_VERSION} \
        && make KVER=${KERNEL_VERSION}
    
    # Collect modules
    RUN mkdir -p /opt/lib/modules/${KERNEL_VERSION}/extra/vastnfs \
        && find /build -name "*.ko" -exec cp {} /opt/lib/modules/${KERNEL_VERSION}/extra/vastnfs/ \;
    
    # Final image
    FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
    
    ARG KERNEL_VERSION
    
    RUN microdnf install -y kmod && microdnf clean all
    
    COPY --from=builder /opt/lib/modules/${KERNEL_VERSION}/extra/vastnfs/*.ko \
         /opt/lib/modules/${KERNEL_VERSION}/extra/vastnfs/
```

### Step 4: Create the KMM Module Resource

```yaml
# 03-vastnfs-module.yaml
apiVersion: kmm.sigs.x-k8s.io/v1beta1
kind: Module
metadata:
  name: vastnfs
  namespace: vastnfs-kmm
spec:
  moduleLoader:
    container:
      modprobe:
        moduleName: sunrpc
        dirName: /opt/lib/modules
        parameters:
          - nfs_bundle_version=4.0.35
      
      kernelMappings:
        # Match any x86_64 kernel - KMM will build for each unique kernel version
        - regexp: '^.*\.x86_64$'
          containerImage: "your-registry.example.com/vastnfs:${KERNEL_FULL_VERSION}"
          build:
            dockerfileConfigMap:
              name: vastnfs-dockerfile
            buildArgs:
              - name: VASTNFS_VERSION
                value: "4.0.35"
  
  # Optional: Only deploy to specific nodes
  selector:
    node-role.kubernetes.io/worker: ""
  
  # Service account for privileged operations
  serviceAccountName: vastnfs-loader
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vastnfs-loader
  namespace: vastnfs-kmm
```

### Step 5: Apply Everything

```bash
kubectl apply -f 01-namespace.yaml
kubectl apply -f 02-dockerfile-configmap.yaml
kubectl apply -f 03-vastnfs-module.yaml
```

### Step 6: Monitor the Deployment

```bash
# Watch the build pods
kubectl -n vastnfs-kmm get pods -w

# Check build logs
kubectl -n vastnfs-kmm logs -l kmm.node.kubernetes.io/module.name=vastnfs -f

# Check Module status
kubectl -n vastnfs-kmm get module vastnfs -o yaml

# Verify modules are loaded on nodes
kubectl debug node/<node-name> -- chroot /host lsmod | grep -E "(sunrpc|nfs)"
kubectl debug node/<node-name> -- chroot /host cat /sys/module/sunrpc/parameters/nfs_bundle_version
```

---

### Key Differences: OCP vs NKE

| Aspect | OpenShift (OCP) | NKE (Vanilla K8s) |
|--------|-----------------|-------------------|
| **KMM Source** | OperatorHub (Red Hat) | Upstream (kubernetes-sigs) |
| **API Version** | `kmm.sigs.x-k8s.io/v1beta1` | Same |
| **Internal Registry** | Built-in (`image-registry.openshift-image-registry.svc`) | Need external or install Harbor |
| **Base Image for Builds** | Driver Toolkit (DTK) auto-detected | May need manual specification |
| **Security Context** | SCC (Security Context Constraints) | PSS/PSP |

---

### Potential Challenges on NKE

#### 1. Container Registry

NKE doesn't have a built-in registry like OpenShift. Options:

```bash
# Option A: Use external registry (Docker Hub, Quay, etc.)
containerImage: "docker.io/youruser/vastnfs:${KERNEL_FULL_VERSION}"

# Option B: Deploy Harbor on NKE
helm repo add harbor https://helm.goharbor.io
helm install harbor harbor/harbor -n harbor --create-namespace

# Option C: Use Nutanix Objects with S3-compatible registry
```

#### 2. Driver Toolkit (DTK) Equivalent

OpenShift has a "Driver Toolkit" image with kernel headers. For NKE, you need to specify a base image with kernel-devel:

```yaml
# In the Dockerfile ConfigMap, replace DTK_AUTO with a specific image
ARG DTK_AUTO=registry.access.redhat.com/ubi9/ubi:latest

# Or for the exact kernel, pre-build a DTK-like image:
ARG DTK_AUTO=your-registry/dtk:5.14.0-284.30.1.el9_2.x86_64
```

#### 3. Kernel Headers Availability

You may need to create a "Driver Toolkit" equivalent for your NKE nodes:

```dockerfile
# dtk.Dockerfile - Build this once per kernel version
FROM registry.access.redhat.com/ubi9/ubi:latest

ARG KERNEL_VERSION

RUN dnf install -y \
    kernel-devel-${KERNEL_VERSION} \
    kernel-headers-${KERNEL_VERSION} \
    gcc \
    make \
    elfutils-libelf-devel \
    && dnf clean all

# Build and push as: your-registry/dtk:${KERNEL_VERSION}
```

---

### Adapting the OpenShift VAST NFS Repo for NKE

You can fork the [vast-data/openshift-vastnfs-kmm-operator](https://github.com/vast-data/openshift-vastnfs-kmm-operator) and make these changes:

```bash
# Clone the repo
git clone https://github.com/vast-data/openshift-vastnfs-kmm-operator
cd openshift-vastnfs-kmm-operator

# Key files to modify:
# 1. k8s/base/kustomization.yaml - Update image references
# 2. k8s/base/module.yaml - Change registry URL, remove OCP-specific settings
# 3. Makefile - Update to work without 'oc' command (use 'kubectl')
```

#### Changes Needed

| File | Change |
|------|--------|
| `Makefile` | Replace `oc` with `kubectl` |
| `k8s/base/module.yaml` | Change image registry from OpenShift internal to your registry |
| `k8s/base/namespace.yaml` | Add Pod Security labels |
| `scripts/*` | Should work as-is |

---

### Summary

**Yes, you can absolutely set up the same VAST NFS + KMM solution on NKE.** The main work is:

1. **Install upstream KMM** (straightforward)
2. **Set up a container registry** (if you don't have one)
3. **Adapt the manifests** from the OpenShift repo (minor changes)
4. **Handle kernel headers** (may need a custom DTK image)
