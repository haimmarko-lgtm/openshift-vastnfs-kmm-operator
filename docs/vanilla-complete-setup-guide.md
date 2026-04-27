# Complete Setup Guide: Kubernetes + KMM Operator + VAST NFS Deployment

This guide provides comprehensive step-by-step instructions for setting up a Kubernetes cluster with the Kernel Module Management (KMM) operator and deploying VAST NFS kernel modules. It covers both **fresh cluster deployments** (image build only) and **production environments with existing NFS mounts** (rolling update strategy).

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Kubernetes Cluster Setup](#3-kubernetes-cluster-setup)
4. [Install the KMM Operator](#4-install-the-kmm-operator)
5. [Set Up the VAST NFS KMM Automation](#5-set-up-the-vast-nfs-kmm-automation)
6. [Prepare Container Registry](#6-prepare-container-registry)
7. [Choose Your Deployment Path](#7-choose-your-deployment-path)
   - [Path A: Fresh Cluster (Image Build Only)](#path-a-fresh-cluster-image-build-only)
   - [Path B: Rolling Update (Existing NFS Mounts)](#path-b-rolling-update-existing-nfs-mounts)
8. [Deploy VAST NFS](#8-deploy-vast-nfs)
9. [Verification](#9-verification)
10. [Upgrading VAST NFS](#10-upgrading-vast-nfs)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Overview

### What We're Building

This guide walks through deploying VAST NFS kernel modules on a Kubernetes cluster using:

- **Kubernetes Cluster**: Any distribution (vanilla K8s, NKP, OpenShift, RKE2, etc.)
- **KMM Operator**: Kernel Module Management operator for building and loading kernel modules
- **VAST NFS KMM Automation**: Automated deployment and management of VAST NFS modules

### Two Deployment Paths

| Scenario | Path | Description |
|----------|------|-------------|
| **Fresh Cluster** | Path A: Image Build Only | No NFS modules currently loaded. KMM builds and deploys directly. |
| **Production Cluster** | Path B: Rolling Update | Nodes have in-tree NFS modules loaded. Requires node-by-node preparation before deployment. |

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                           │
├─────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────┐    ┌─────────────────────────────────────┐ │
│  │   KMM Operator      │    │        Container Registry           │ │
│  │  (kmm-operator-ns)  │    │   (Built module images stored)      │ │
│  └──────────┬──────────┘    └─────────────────────────────────────┘ │
│             │                                                        │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │  VAST NFS Module    │  Triggers build on matching kernel         │
│  │  (vastnfs-kmm ns)   │                                            │
│  └──────────┬──────────┘                                            │
│             │                                                        │
│             ▼                                                        │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    Worker Nodes                               │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │   │
│  │  │  Node 1  │  │  Node 2  │  │  Node 3  │  │  Node N  │      │   │
│  │  │ VAST NFS │  │ VAST NFS │  │ VAST NFS │  │ VAST NFS │      │   │
│  │  │ Modules  │  │ Modules  │  │ Modules  │  │ Modules  │      │   │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘      │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### VAST NFS Benefits

VAST NFS provides enhanced NFS capabilities including:
- **NFS stack improvements** from Linux v5.15.x LTS
- **Multipath support** for NFSv3 and NFSv4.1
- **Nvidia GDS integration** for high-performance workloads
- **Performance optimizations** for enterprise workloads

---

## 2. Prerequisites

### 2.1 Required Tools

| Tool | Version | Purpose |
|------|---------|---------|
| `kubectl` | 1.25+ | Kubernetes CLI |
| `git` | Any | Clone repository |
| `make` | Any | Build automation |
| `curl` | Any | Download dependencies |

### 2.2 Cluster Requirements

| Requirement | Details |
|-------------|---------|
| Kubernetes Version | 1.25+ |
| Node OS | Linux (Ubuntu, RHEL, Rocky, SUSE, CoreOS, etc.) |
| Node Access | SSH or privileged pod access |
| Container Registry | Internal or external registry accessible from nodes |
| Cluster Permissions | Cluster admin (for CRD installation) |

### 2.3 Prepare Your Workstation

```bash
# Install kubectl (if not present)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

# Verify kubectl
kubectl version --client

# Ensure you have cluster access
kubectl get nodes
```

---

## 3. Kubernetes Cluster Setup

Choose one of the following options based on your environment:

### Option A: Existing Kubernetes Cluster

If you already have a running cluster, skip to [Section 4](#4-install-the-kmm-operator).

Verify your cluster:

```bash
# Check cluster status
kubectl cluster-info

# Verify nodes are ready
kubectl get nodes -o wide

# Check node kernel versions (important for module compatibility)
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kernelVersion}{"\n"}{end}'
```

### Option B: Quick Lab Cluster with Kind

For testing/development:

```bash
# Install Kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Create cluster with multiple worker nodes
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
EOF

# Verify cluster
kubectl get nodes
```

## 4. Install the KMM Operator

The Kernel Module Management (KMM) operator manages the lifecycle of kernel modules in Kubernetes.

### 4.1 Installation Method Selection

Choose based on your Kubernetes distribution:

| Distribution | Recommended Method |
|--------------|-------------------|
| OpenShift | OperatorHub (GUI) or CLI |
| Vanilla K8s | YAML manifests |

### 4.2 Install KMM on Vanilla Kubernetes

KMM requires **cert-manager** as a dependency. Install both components:

```bash
# Step 1: Install cert-manager (required dependency)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl -n cert-manager wait --for=condition=Available deployment \
    cert-manager \
    cert-manager-cainjector \
    cert-manager-webhook \
    --timeout=120s

# Verify cert-manager is running
kubectl get pods -n cert-manager
```

```bash
# Step 2: Install KMM operator using kustomize
kubectl apply -k https://github.com/kubernetes-sigs/kernel-module-management/config/default

# Wait for KMM operator to be ready
kubectl -n kmm-operator-system wait --for=condition=Available deployment \
    kmm-operator-controller \
    --timeout=120s

# Verify installation
kubectl get pods -n kmm-operator-system
kubectl get crds | grep kmm
```

Expected output:
```
NAME                                       READY   STATUS    RESTARTS   AGE
kmm-operator-controller-xxxxxxxxx-xxxxx    1/1     Running   0          30s

modules.kmm.sigs.x-k8s.io                  2024-01-15T10:00:00Z
```

> **Note:** If `kubectl apply -k` fails, ensure you have a recent version of kubectl (1.21+) which includes kustomize support.

### 4.3 Install KMM on OpenShift

**Option A: Via OperatorHub (Recommended for OpenShift)**

1. Log in to OpenShift Console
2. Navigate to **Operators** → **OperatorHub**
3. Search for "Kernel Module Management"
4. Click **Install**
5. Select installation options:
   - Update channel: `stable`
   - Installation mode: `All namespaces on the cluster`
   - Namespace: `openshift-kmm`
6. Click **Install**

**Option B: Via CLI**

```bash
# Create namespace
oc create namespace openshift-kmm

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kernel-module-management
  namespace: openshift-kmm
spec:
  targetNamespaces:
    - openshift-kmm
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kernel-module-management
  namespace: openshift-kmm
spec:
  channel: stable
  name: kernel-module-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Verify installation
oc get pods -n openshift-kmm
```

### 4.4 Verify KMM Installation

```bash
# Check operator is running
kubectl get pods -n kmm-operator-system -l app.kubernetes.io/component=kmm

# Check CRDs are installed
kubectl get crd modules.kmm.sigs.x-k8s.io

# Check operator logs
kubectl logs -n kmm-operator-system -l app.kubernetes.io/component=kmm --tail=20
```

---

## 5. Set Up the VAST NFS KMM Automation

### 5.1 Clone the Repository

```bash
# Clone the unified VAST NFS KMM automation repository
git clone https://github.com/vast-data/openshift-vastnfs-kmm-operator.git
cd openshift-vastnfs-kmm-operator

# View available make targets
make help
```

### 5.2 Understand the Directory Structure

```
openshift-vastnfs-kmm-operator/
├── Makefile                    # Main automation entry point
├── k8s/
│   ├── base/                   # Base Kustomize configuration
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── vastnfs.module.yaml        # KMM Module definition
│   │   ├── vastnfs-kmm-sa.yaml        # ServiceAccount
│   │   └── vastnfs-kmm-build-dockerfile.cm.yaml  # Build Dockerfile
│   └── overlays/
│       ├── secure-boot/        # Secure boot configuration
│       └── with-pull-secret/   # Private registry configuration
├── scripts/
│   ├── install_and_follow_logs.sh
│   ├── prepare_node_for_vastnfs.sh    # Single node preparation
│   ├── prepare_all_workers.sh         # Rolling update all workers
│   ├── graceful_unload.sh
│   ├── verify_deployment.sh
│   └── common.sh
└── docs/
```

### 5.3 Configure Environment Variables

**Required variables** (no defaults - must be set explicitly):

```bash
# REQUIRED: VAST NFS version to deploy
export VASTNFS_VERSION=4.5.5

# REQUIRED: Container registry for built module images
# Replace with your registry IP/hostname and port
export KMM_IMG_REPO=<REGISTRY_IP>:<PORT>/vastnfs
```

**Optional variables** (have sensible defaults):

```bash
# Optional: Customize namespace (default: vastnfs-kmm)
export NAMESPACE=vastnfs-kmm

# Optional: Build base image (auto-detected from cluster nodes)
# If not set, automatically detected based on node OS:
#   Ubuntu/Debian nodes  -> ubuntu:22.04
#   Rocky/RHEL 9 nodes   -> rockylinux:9
#   Fedora nodes         -> fedora:latest
#   SUSE nodes           -> opensuse/leap
# To check auto-detection: make detect-build-image
# To override: export BUILD_IMAGE=rockylinux:9

# Optional: Pull secret for private registries
# export KMM_PULL_SECRET=my-registry-secret
```

> **Important:** All `make` commands will fail with a clear error message if `VASTNFS_VERSION` or `KMM_IMG_REPO` are not set. This prevents accidental deployments with incorrect configuration.

### Build Image Auto-Detection

The operator automatically detects your cluster's node OS and selects the appropriate build image:

```bash
# Check what build image will be auto-detected
make detect-build-image

# Example output:
# Cluster node OS:     Ubuntu 22.04.3 LTS
# Cluster node kernel: 6.8.0-107-generic
# Auto-detected BUILD_IMAGE: ubuntu:22.04
```

**Auto-detection mapping:**

| Node OS | Auto-detected BUILD_IMAGE |
|---------|--------------------------|
| Ubuntu / Debian | `ubuntu:22.04` |
| Rocky Linux 9 / RHEL 9 / Alma 9 | `rockylinux:9` |
| Rocky Linux 8 / RHEL 8 / CentOS 8 | `rockylinux:8` |
| Fedora | `fedora:latest` |
| SUSE / openSUSE | `opensuse/leap` |
| Flatcar / CoreOS / Talos | `fedora:latest` |

### Kernel Compatibility Validation

The build process validates that the build image matches your target kernel. If there's a mismatch (e.g., trying to build Ubuntu kernel modules with a Rocky Linux image), you'll get a clear error:

```
========================================================
ERROR: Kernel/Build-Image Mismatch Detected!
========================================================

  Target kernel:  6.8.0-107-generic
  Kernel type:    debian
  Build image:    rocky

SOLUTION: Use a matching build image:
  - For Ubuntu kernels (-generic):      BUILD_IMAGE=ubuntu:22.04
  - For RHEL/Rocky/Alma kernels (.el9): BUILD_IMAGE=rockylinux:9
```

This prevents confusing errors during the build process.

---

## 6. Prepare Container Registry

KMM needs a container registry to store the built kernel module images.

### Option A: Deploy Local Registry with NodePort

For clusters without an internal registry:

```bash
# Create namespace
kubectl create namespace registry

# Deploy registry with NodePort
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        env:
        - name: REGISTRY_STORAGE_DELETE_ENABLED
          value: "true"
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: registry
spec:
  type: NodePort
  selector:
    app: registry
  ports:
  - port: 5000
    targetPort: 5000
    nodePort: 30500
EOF

# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Configure KMM to use this registry
export KMM_IMG_REPO=${NODE_IP}:30500/vastnfs

echo "Registry URL: ${KMM_IMG_REPO}"
```

### Option B: Use OpenShift Internal Registry

For OpenShift clusters:

```bash
# The internal registry is already available
export KMM_IMG_REPO=image-registry.openshift-image-registry.svc:5000/vastnfs-kmm/vastnfs
```

### Option C: Use External Registry

For external registries (Docker Hub, Quay, Harbor, etc.):

```bash
# Set registry URL
export KMM_IMG_REPO=registry.example.com/vastnfs

# Create pull secret if needed
kubectl create secret docker-registry my-registry-secret \
  --docker-server=registry.example.com \
  --docker-username=<username> \
  --docker-password=<password> \
  -n vastnfs-kmm

export KMM_PULL_SECRET=my-registry-secret
```

### Configure Insecure Registry (If Using HTTP)

If using an insecure (HTTP) registry, configure containerd on each node:

```bash
# On each node, add to /etc/containerd/config.toml or create /etc/containerd/certs.d/<registry>/hosts.toml
mkdir -p /etc/containerd/certs.d/${NODE_IP}:30500
cat <<EOF > /etc/containerd/certs.d/${NODE_IP}:30500/hosts.toml
server = "http://${NODE_IP}:30500"

[host."http://${NODE_IP}:30500"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

# Restart containerd
systemctl restart containerd
```

---

## 7. Choose Your Deployment Path

Before deploying VAST NFS, determine which path applies to your environment:

| Scenario | Path | Action |
|----------|------|--------|
| Fresh cluster, no NFS mounts | **Path A** | Skip to [Section 8](#8-deploy-vast-nfs) |
| New nodes, no NFS activity yet | **Path A** | Skip to [Section 8](#8-deploy-vast-nfs) |
| Production cluster with NFS workloads | **Path B** | Continue with Rolling Update below |
| Nodes using NFS for storage classes | **Path B** | Continue with Rolling Update below |
| kubelet using NFS-backed volumes | **Path B** | Continue with Rolling Update below |

---

### Path A: Fresh Cluster (Image Build Only)

If your cluster has **no existing NFS mounts or in-tree NFS modules loaded**, deployment is straightforward:

1. **Prerequisites complete**: KMM operator installed, registry configured
2. **Skip to Section 8**: Deploy VAST NFS directly
3. **KMM handles everything**: Builds module image, pushes to registry, loads modules

**Verify no NFS modules are loaded:**

```bash
# Check all nodes for existing NFS modules
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== Node: $node ==="
  kubectl debug node/$node -it --image=alpine -- chroot /host sh -c '
    if lsmod | grep -qE "^(nfs|sunrpc)"; then
      echo "WARNING: NFS modules detected - use Path B (Rolling Update)"
      lsmod | grep -E "(nfs|sunrpc)"
    else
      echo "OK: No NFS modules loaded - safe to use Path A"
    fi
  ' 2>/dev/null
done
```

If all nodes show "OK: No NFS modules loaded", proceed directly to [Section 8: Deploy VAST NFS](#8-deploy-vast-nfs).

---

### Path B: Rolling Update (Existing NFS Mounts)

**This section is CRITICAL for production systems with existing NFS mounts.**

The in-tree Linux NFS modules must be unloaded before VAST NFS modules can be loaded. For systems with active NFS workloads, this requires careful orchestration.

#### Rolling Update Strategy Overview

The rolling update process for each node:

```
┌─────────────────────────────────────────────────────────────┐
│                    For Each Worker Node                      │
├─────────────────────────────────────────────────────────────┤
│  1. CORDON       - Mark node unschedulable                  │
│         ↓                                                    │
│  2. DRAIN        - Evict all pods (except DaemonSets)       │
│         ↓                                                    │
│  3. STOP SERVICES- Stop NFS/RPC services (systemd)          │
│         ↓                                                    │
│  4. UNMOUNT      - Unmount all NFS filesystems              │
│         ↓                                                    │
│  5. UNLOAD       - Iteratively unload NFS kernel modules    │
│         ↓                                                    │
│  6. UNCORDON     - Mark node schedulable                    │
│         ↓                                                    │
│  7. DEPLOY       - KMM deploys VAST NFS modules             │
│         ↓                                                    │
│  8. VERIFY       - Confirm VAST NFS is active               │
│         ↓                                                    │
│  9. NEXT NODE    - Proceed to next node                     │
└─────────────────────────────────────────────────────────────┘
```

#### Pre-Flight Checks

Before starting the rolling update:

```bash
# Check current NFS module status on all nodes
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== Node: $node ==="
  kubectl debug node/$node -it --image=alpine -- chroot /host sh -c '
    echo "NFS modules loaded:"
    lsmod | grep -E "(nfs|sunrpc|rpc)" | head -10
    echo ""
    echo "NFS mounts:"
    mount | grep nfs | head -5
    echo ""
  ' 2>/dev/null
done

# Check for pods using NFS volumes - Important to locate directly connected NFS mounts 
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {range .spec.volumes[*]}{.name}={.nfs.server}{" "}{end}{"\n"}{end}' | grep -v ": $"
```

#### Prepare a Single Node

Use this for testing or when you need to prepare specific nodes:

```bash
# REQUIRED: Set environment variables first
export VASTNFS_VERSION=4.5.5
export KMM_IMG_REPO=<your-registry>:30500/vastnfs

# Prepare a single worker node
make prepare-worker NODE=worker-1

# With custom timeout (default: 60 attempts = ~5 minutes)
make prepare-worker NODE=worker-1 MAX_ATTEMPTS=120

# Or pass variables inline
make prepare-worker NODE=worker-1 VASTNFS_VERSION=4.5.5 KMM_IMG_REPO=myregistry:5000/vastnfs
```

**What the script does:**

1. **Cordon**: `kubectl cordon worker-1`
2. **Drain**: `kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data --force`
3. **Stop Services**: Stops rpcbind, nfs-client, rpc-statd, etc.
4. **Kill Processes**: Terminates any remaining RPC processes
5. **Unmount**: Unmounts all NFS and rpc_pipefs filesystems
6. **Unload Modules**: Iteratively unloads nfsd, nfsv4, nfsv3, nfs, lockd, sunrpc, etc.
7. **Uncordon**: `kubectl uncordon worker-1`

#### Rolling Update All Worker Nodes

For production deployments, prepare all workers in sequence:

```bash
# REQUIRED: Set environment variables first
export VASTNFS_VERSION=4.5.5
export KMM_IMG_REPO=<your-registry>:30500/vastnfs

# Prepare all worker nodes (one at a time)
make prepare-workers

# With custom timeout
make prepare-workers MAX_ATTEMPTS=120
```

**Interactive prompts:**

```
================================================================
  VAST NFS Rolling Update - Worker Node Preparation
================================================================

Worker nodes to prepare (3 total):
  - worker-1
      OS: Ubuntu 22.04.3 LTS
      Kernel: 5.15.0-91-generic
      Ready: True
  - worker-2
      OS: Ubuntu 22.04.3 LTS
      Kernel: 5.15.0-91-generic
      Ready: True
  - worker-3
      OS: Ubuntu 22.04.3 LTS
      Kernel: 5.15.0-91-generic
      Ready: True

Processing mode: Rolling update (one node at a time)
Max unload attempts per node: 60
Helper image: alpine:latest

Proceed with rolling update? (y/N)
```

#### Install Systemd Unit (Optional - For Immutable OS)

For immutable OS like CoreOS, Flatcar, or NKE that may reload in-tree NFS on reboot:

```bash
# Install systemd unit to prevent in-tree NFS loading
make install-systemd-unit
```

This creates a systemd service that runs before NFS services and prevents the in-tree modules from loading.

---

### Node Selection and Labeling

The operator provides fine-grained control over which nodes receive VAST NFS deployment using Kubernetes labels.

#### Why Use Node Selection?

- **Staged rollouts**: Deploy to a subset of nodes first, then expand
- **Mixed clusters**: Some nodes need VAST NFS, others don't
- **Maintenance windows**: Control exactly when each node receives the update
- **Testing**: Deploy to test nodes before production nodes

#### Node Selection Workflow

**Option 1: Deploy to all nodes (default)**

```bash
# No node selector - deploys to all nodes matching the kernel
make install
```

**Option 2: Deploy only to labeled nodes**

```bash
# First, include nodes that should receive VAST NFS
make add-node-to-kmm NODE=worker-1
make add-node-to-kmm NODE=worker-2

# Then install with node selector
make install NODE_SELECTOR="vastnfs-kmm/enabled=true"
```

**Option 3: Prepare nodes manually, skip KMM auto-deployment**

```bash
# Prepare nodes one at a time, marking them to skip KMM
make prepare-worker NODE=worker-1 LABEL_SKIP=true
make prepare-worker NODE=worker-2 LABEL_SKIP=true

# These nodes now have VAST NFS loaded but KMM won't manage them
```

#### Node Selection Commands

```bash
# Show KMM deployment status for all nodes
make show-node-labels

# Include a node in KMM deployment
make add-node-to-kmm NODE=worker-1

# Exclude a node from KMM deployment
make remove-node-from-kmm NODE=worker-1

# Delete Module but keep built images (for re-deployment later)
make delete-module
```

#### Understanding LABEL_SKIP

When using `LABEL_SKIP=true` with `prepare-worker`:

1. The node is prepared (drained, NFS unloaded, VAST NFS loaded)
2. After success, the `vastnfs-kmm/enabled` label is **removed**
3. The KMM Module selector is set to require `vastnfs-kmm/enabled=true`
4. KMM will **not** create a worker pod on this node (it's already prepared)

This is useful when you want to:
- Manually control the preparation timing
- Avoid KMM trying to reload modules on already-prepared nodes
- Maintain VAST NFS without KMM's ongoing management

---

## 8. Deploy VAST NFS

This section applies to both deployment paths:
- **Path A (Fresh Cluster)**: Proceed directly with installation
- **Path B (Rolling Update)**: Proceed after completing node preparation in Section 7

### 8.1 Understanding the Build Process

When you deploy the KMM Module, the KMM operator performs these steps automatically:

```
┌─────────────────────────────────────────────────────────────────┐
│                    KMM Build & Deploy Flow                       │
├─────────────────────────────────────────────────────────────────┤
│  1. DETECT       - KMM detects nodes matching module selector   │
│         ↓                                                        │
│  2. BUILD        - Creates build pod for each unique kernel     │
│         ↓         version in the cluster                        │
│  3. COMPILE      - Downloads VAST NFS source, compiles modules  │
│         ↓         against kernel headers                        │
│  4. PUSH         - Pushes built image to container registry     │
│         ↓         (tagged with kernel version)                  │
│  5. DEPLOY       - Creates DaemonSet to load modules on nodes   │
│         ↓                                                        │
│  6. LOAD         - Worker pods load VAST NFS kernel modules     │
└─────────────────────────────────────────────────────────────────┘
```

**Key points about the build:**
- Build runs **once per unique kernel version** in your cluster
- Built images are cached in your registry for future use
- If image already exists for a kernel version, build is skipped
- Build typically takes 2-5 minutes depending on cluster resources

### 8.2 Standard Installation

```bash
# REQUIRED: Set environment variables (no defaults)
export VASTNFS_VERSION=4.5.5                    # Your desired VAST NFS version
export KMM_IMG_REPO=<your-registry>:30500/vastnfs  # Your container registry

# Install VAST NFS with real-time log monitoring
make install

# Alternative: Pass variables inline
make install VASTNFS_VERSION=4.5.5 KMM_IMG_REPO=myregistry:5000/vastnfs
```

> **Note:** The install command will fail with an error if `VASTNFS_VERSION` or `KMM_IMG_REPO` are not set. This is intentional to prevent deployments with incorrect configuration.

**What happens:**

1. Creates the namespace (if not exists)
2. Checks if VAST NFS is already loaded (handles upgrades)
3. Builds kustomize manifests with your configuration
4. Applies the KMM Module, ConfigMap, and ServiceAccount
5. KMM operator detects the Module and:
   - Creates a build pod to compile VAST NFS for your kernel
   - Pushes the built image to your registry
   - Creates a DaemonSet to load modules on matching nodes

### 8.3 Monitor the Build Process

```bash
# Watch pods in the namespace
kubectl get pods -n vastnfs-kmm -w

# View build logs
kubectl logs -f -l kmm.node.kubernetes.io/module.name=vastnfs -n vastnfs-kmm

# Check KMM operator logs
kubectl logs -n kmm-operator-system -l app.kubernetes.io/component=kmm -f
```

**Expected pod lifecycle:**

```
NAME                           READY   STATUS      AGE
vastnfs-build-xxxxx            0/1     Init        0s
vastnfs-build-xxxxx            1/1     Running     5s      # Building modules
vastnfs-build-xxxxx            0/1     Completed   3m      # Build done
vastnfs-xxxxx-xxxxx            1/1     Running     3m      # Worker pods loading modules
```

### 8.4 Pre-Build Images Only (Without Loading)

In some scenarios, you may want to build and cache the module images without immediately loading them on nodes. This is useful for:

- **Air-gapped environments**: Pre-build images before disconnecting from the internet
- **Staging**: Prepare images before a maintenance window
- **Multi-cluster**: Build once, deploy to multiple clusters

**Option 1: Generate manifests without applying**

```bash
# REQUIRED: Set environment variables
export VASTNFS_VERSION=4.5.5
export KMM_IMG_REPO=<your-registry>:30500/vastnfs

# Generate manifests to dist/install.yaml for review or manual application
make build-installer

# Review the generated manifests
cat dist/install.yaml

# Apply manually when ready
kubectl apply -f dist/install.yaml
```

**Option 2: Deploy with node selector that matches no nodes initially**

You can modify the Module's node selector to control deployment:

```bash
# Deploy normally first to trigger the build
make install

# KMM will build the image even if no nodes match the selector
# Note: KMM Module selector only supports simple label matching (not matchExpressions)
# To deploy only to nodes with a specific label:
kubectl patch module vastnfs -n vastnfs-kmm --type=merge -p '{"spec":{"selector":{"vastnfs-kmm/enabled":"true"}}}'

# Then label nodes you want to receive the deployment:
kubectl label node <node-name> vastnfs-kmm/enabled=true
```

**Option 3: Check if image exists in registry**

```bash
# After build completes, verify image was pushed
KERNEL_VERSION=$(uname -r)
curl -s http://<registry-ip>:<port>/v2/vastnfs/tags/list | grep -q "${KERNEL_VERSION}" && \
  echo "Image ready for kernel ${KERNEL_VERSION}" || \
  echo "Image not found"
```

### 8.5 Reinstalling VAST NFS

If VAST NFS is already loaded on nodes and you need to reinstall the KMM Module (e.g., after deleting it), use the `reinstall` target:

```bash
# When VAST NFS modules are already loaded
make reinstall VASTNFS_VERSION=4.5.5 KMM_IMG_REPO=myregistry:5000/vastnfs
```

**When to use `reinstall` vs `install`:**

| Scenario | Command | Notes |
|----------|---------|-------|
| Fresh installation | `make install` | No VAST NFS currently loaded |
| Upgrade to new version | `make install` | Auto-detects and handles graceful unload |
| Module deleted, VAST NFS still loaded | `make reinstall` | Skips in-tree module removal |
| Development/testing cycles | `make reinstall` | Faster iteration |

The `reinstall` target:
- Uses a special overlay that omits `inTreeModulesToRemove`
- Prevents "module in use" errors when VAST NFS is already active
- Ideal for development and testing scenarios

### 8.6 Secure Boot Installation

For systems with Secure Boot enabled:

```bash
# Generate/reuse signing keys, stage MOK if needed, and deploy once trusted
make install-secure-boot

# Or use existing signing keys with the same target
make install-secure-boot \
  PRIVATE_KEY_FILE=/path/to/signing.key \
  PUBLIC_CERT_FILE=/path/to/signing.der
```

> **Note:** Secure boot installations require the public signing cert to be enrolled in the MOK (Machine Owner Key) database. If enrollment is missing, rerun with `MOK_PASSWORD_FILE=/secure/mok-password`; the command stages the cert and exits with reboot instructions.

---

## 9. Verification

### 9.1 Automatic Verification

Wait approximately 1-2 minutes after installation, then:

```bash
# Verify all nodes
make verify

# Verify a single node
make verify NODE=worker-1

# Detailed verification with extra diagnostics
make verify VERBOSE=true

# Combine options
make verify NODE=worker-1 VERBOSE=true
```

**Expected output:**

```
================================================================
  VAST NFS Deployment Verification
================================================================

[STEP] Checking KMM Module Status
[INFO] Module found: vastnfs
NAME      AGE
vastnfs   5m

[STEP] Verifying VAST NFS is Active on Nodes
[INFO] Checking node: worker-1
[SUCCESS] VAST NFS ACTIVE - version: 4.5.5
[INFO] Checking node: worker-2
[SUCCESS] VAST NFS ACTIVE - version: 4.5.5
[INFO] Checking node: worker-3
[SUCCESS] VAST NFS ACTIVE - version: 4.5.5

[INFO] Summary: 3/3 nodes have VAST NFS active

[SUCCESS] ✅ VAST NFS deployment verification PASSED
```

### 9.2 Manual Verification

```bash
# Check Module status
kubectl get module vastnfs -n vastnfs-kmm -o wide

# Check VAST NFS version on each node
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $node ==="
  kubectl debug node/$node -it --image=alpine -- chroot /host \
    cat /sys/module/sunrpc/parameters/nfs_bundle_version 2>/dev/null || echo "VAST NFS not active"
done

# Check loaded modules on a node
kubectl debug node/<node-name> -it --image=alpine -- chroot /host \
  lsmod | grep -E "(sunrpc|nfs|rpc)"

# Check KMM worker pods
kubectl get pods -n vastnfs-kmm -o wide

# Check events
kubectl get events -n vastnfs-kmm --sort-by='.lastTimestamp' | tail -10
```

### 9.3 Verify NFS Functionality

Test that NFS mounts work with the new modules:

```bash
# Create a test pod that mounts an NFS share
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nfs-test
spec:
  containers:
  - name: test
    image: busybox
    command: ['sh', '-c', 'ls -la /mnt && sleep 3600']
    volumeMounts:
    - name: nfs-volume
      mountPath: /mnt
  volumes:
  - name: nfs-volume
    nfs:
      server: <NFS_SERVER_IP>
      path: /exported/path
EOF

# Check if mount succeeded
kubectl exec nfs-test -- mount | grep nfs
kubectl exec nfs-test -- ls -la /mnt

# Clean up
kubectl delete pod nfs-test
```

---

## 10. Upgrading VAST NFS

Upgrading is handled automatically by the Makefile:

```bash
# Set the new version and registry
export VASTNFS_VERSION=4.6.0              # New version to upgrade to
export KMM_IMG_REPO=<your-registry>:30500/vastnfs

# Run install (automatically handles graceful unload if already installed)
make install

# Wait 1-2 minutes, then verify
make verify
```

**What happens during upgrade:**

1. Detects VAST NFS is already loaded
2. Performs graceful unload on all nodes
3. Deploys the new version
4. KMM builds new module image with updated version tag
5. Rolls out to all nodes

---

## 11. Troubleshooting

### 11.1 Common Issues

**Issue: Build pod fails**

```bash
# Check build pod logs
kubectl logs -l kmm.node.kubernetes.io/module.name=vastnfs -n vastnfs-kmm --tail=100

# Common causes:
# - Kernel headers not available for your kernel version
# - Registry not accessible
# - Network issues downloading VAST NFS source
# - GCC version mismatch (see below)
```

**Issue: GCC version mismatch during build**

If you see errors like `gcc: error: unrecognized command-line option '-ftrivial-auto-var-init=zero'`, your kernel was compiled with a newer GCC version than is available in the build image.

```bash
# Check the build logs for compiler warnings:
# "warning: the compiler differs from the one used to build the kernel"
# "The kernel was built by: x86_64-linux-gnu-gcc-12"
# "You are using: gcc (Ubuntu 11.4.0)"

# Solution: Use Ubuntu 22.04 as the build image which includes GCC 12
export BUILD_IMAGE=ubuntu:22.04
make install
```

The Dockerfile automatically installs GCC 12 on Ubuntu and configures it as the default compiler for newer kernels (6.x+).

**Issue: Module not loading on nodes**

```bash
# Check if DaemonSet pods exist
kubectl get pods -n vastnfs-kmm -o wide

# Check worker pod logs
kubectl logs <worker-pod-name> -n vastnfs-kmm

# Check for module conflicts
kubectl debug node/<node-name> -it --image=alpine -- chroot /host sh -c '
  lsmod | grep sunrpc
  dmesg | tail -30 | grep -i nfs
'
```

**Issue: Module unload fails during rolling update**

```bash
# Check what's using the modules
kubectl debug node/<node-name> -it --image=alpine -- chroot /host sh -c '
  lsmod | grep sunrpc
  mount | grep nfs
  fuser -v /proc/fs/nfsd 2>&1 || true
'

# Force cleanup (use with caution)
kubectl debug node/<node-name> -it --image=alpine --profile=sysadmin -- chroot /host sh -c '
  umount -f $(mount | grep nfs | awk "{print \$3}") 2>/dev/null || true
  systemctl stop rpcbind nfs-client.target rpc-statd 2>/dev/null || true
  rmmod sunrpc 2>/dev/null || true
'
```

**Issue: KMM worker pods in CrashLoopBackOff after deleting Module**

```bash
# Error: modprobe: FATAL: Module sunrpc is in use.
# This happens when VAST NFS is loaded and you try to reinstall

# Solution 1: Use reinstall target (recommended)
make reinstall

# Solution 2: If VAST NFS is already loaded and working, exclude from KMM management
make remove-node-from-kmm NODE=<node-name>
```

**Issue: Need to clean up leftover helper pods**

```bash
# Clean up all debug/helper pods created by the scripts
make clean-debug-pods
```

**Issue: Registry push fails**

```bash
# Verify registry is accessible
curl -X GET http://<registry-ip>:<port>/v2/_catalog

# Check if insecure registry is configured on nodes
kubectl debug node/<node-name> -it --image=alpine -- chroot /host sh -c '
  cat /etc/containerd/certs.d/*/hosts.toml 2>/dev/null || echo "No custom certs.d"
  cat /etc/docker/daemon.json 2>/dev/null || echo "No docker daemon.json"
'
```

### 11.2 Debug Commands Reference

```bash
# Check all resources in namespace
kubectl get all -n vastnfs-kmm

# Describe the Module
kubectl describe module vastnfs -n vastnfs-kmm

# Check KMM operator logs
kubectl logs -n kmm-operator-system deployment/kmm-operator-controller --tail=50

# Check events
kubectl get events -n vastnfs-kmm --sort-by='.lastTimestamp'

# Node-level debugging
kubectl debug node/<node-name> -it --image=alpine -- chroot /host bash

# Check kernel module info
kubectl debug node/<node-name> -it --image=alpine -- chroot /host modinfo sunrpc
```

### 11.3 Uninstall VAST NFS

```bash
# Complete removal (graceful unload + delete all resources and namespace)
make uninstall
```

---

## Quick Reference

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `VASTNFS_VERSION` | **Yes** | None | VAST NFS version to deploy (e.g., `4.5.5`) |
| `KMM_IMG_REPO` | **Yes** | None | Container registry for module images (e.g., `myregistry:5000/vastnfs`) |
| `NAMESPACE` | No | `vastnfs-kmm` | Kubernetes namespace |
| `BUILD_IMAGE` | No | Auto-detected | Base image for module building (auto-detected from cluster node OS) |
| `KMM_PULL_SECRET` | No | Empty | Pull secret for private registries |
| `HELPER_IMAGE` | No | `alpine:latest` | Image for node preparation pods |
| `NODE_SELECTOR` | No | Empty | Label selector to filter which nodes receive deployment |
| `MAX_ATTEMPTS` | No | `60` | Maximum unload attempts for node preparation (~3 seconds each) |
| `LABEL_SKIP` | No | `false` | When `true`, removes enabled label after successful prepare-worker |

### Make Targets

#### Core Installation

| Target | Description |
|--------|-------------|
| `make build-only` | Build kernel module images and push to registry (no deployment) |
| `make build-only FORCE=true` | Force rebuild - clears registry and node caches first |
| `make install` | Install/upgrade VAST NFS with log monitoring |
| `make reinstall` | Reinstall when VAST NFS is already loaded (skips in-tree module removal) |
| `make uninstall` | Complete removal, including namespace deletion (use `FORCE=true` to skip busy nodes) |

#### Node Preparation

| Target | Description |
|--------|-------------|
| `make prepare-worker NODE=<name>` | Prepare single worker node (drain, unload NFS, load VAST NFS) |
| `make prepare-worker NODE=<name> LABEL_SKIP=true` | Prepare node and mark to skip future KMM deployments |
| `make prepare-workers` | Rolling update all worker nodes |
| `make install-systemd-unit` | Install systemd unit to prevent in-tree NFS on boot (immutable OS) |

#### Node Selection & Labeling

| Target | Description |
|--------|-------------|
| `make add-node-to-kmm NODE=<name>` | Include a node in KMM module deployment |
| `make remove-node-from-kmm NODE=<name>` | Exclude a node from KMM module deployment |
| `make show-node-labels` | Show KMM deployment status for all nodes |
| `make delete-module` | Delete Module and worker pods (keeps built images) |

#### Verification & Diagnostics

| Target | Description |
|--------|-------------|
| `make verify` | Verify deployment status on all nodes |
| `make verify NODE=<name>` | Verify deployment on a single node |
| `make verify VERBOSE=true` | Detailed verification with extra diagnostics |
| `make show-config` | Show current configuration |
| `make clean-debug-pods` | Clean up leftover helper pods from all namespaces |

#### Secure Boot

| Target | Description |
|--------|-------------|
| `make install-secure-boot` | Resumable Secure Boot install, key handling, MOK staging, and signed deployment |
| `make generate-secure-boot-keys` | Optional helper to generate secure boot signing keys |
| `make verify-secure-boot` | Verify Secure Boot state and module signatures on all target nodes |

#### Utilities

| Target | Description |
|--------|-------------|
| `make build-installer` | Generate manifests to `dist/install.yaml` |
| `make help` | Show all available targets |

---

## Additional Resources

- [VAST NFS Documentation](https://vastnfs.vastdata.com/docs/4.0/Intro.html)
- [KMM Operator Documentation](https://kmm.sigs.k8s.io/)
- [NKP vSphere Installation Guide](./nkp-vsphere-installation-guide.md)

---

*Guide Version: 1.2*  
*Last Updated: April 2026*
