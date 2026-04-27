# VAST NFS KMM Operator on Vanilla Kubernetes

> This page is the vanilla Kubernetes guide for the unified VAST NFS KMM operator repository.
> For the OpenShift guide see [openshift.md](openshift.md); for a comparison see
> [openshift-vs-vanilla.md](openshift-vs-vanilla.md). The top-level
> [README](../README.md) is the entry point for both platforms.

On non-OpenShift clusters the `Makefile` auto-detects `PLATFORM=vanilla` and uses the
multi-distro overlay at `k8s/overlays/vanilla/base`. `KUBE_CMD` defaults to `kubectl`. Unlike
OpenShift, `VASTNFS_VERSION` and `KMM_IMG_REPO` are required (there is no internal registry to
default to).

This page covers automated deployment and management of **VAST NFS kernel modules** on **any Kubernetes cluster** using the upstream [Kernel Module Management (KMM)](https://kmm.sigs.k8s.io/) operator — supporting Ubuntu, RHEL/Rocky/Alma, Fedora, SUSE, and immutable OSes like Flatcar/Talos — on Rancher, NKP/NKE, Tanzu, and others.

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Installation Methods](#installation-methods)
- [Usage](#usage)
- [Verification](#verification)
- [Documentation](#documentation)

## Overview

This KMM (Kernel Module Management) operator enables automatic deployment and management of **VAST NFS kernel modules** across Kubernetes clusters with **multi-distribution support**.

**VAST NFS** is a high-performance NFS implementation that provides a modified version of the Linux NFS client and server kernel code stacks. It contains backported upstream NFS stack code from Linux v5.15.x LTS kernel branch, allowing older kernels to receive the full functionality of newer NFS stack code.

For complete VAST NFS documentation, refer to the [official VAST NFS documentation](https://vastnfs.vastdata.com/docs/4.0/Intro.html).

### VAST NFS Features

VAST NFS provides enhanced NFS capabilities including:

- **NFS stack improvements and fixes** from Linux v5.15.x LTS
- **Multipath support** for NFSv3 and NFSv4.1
- **Nvidia GDS integration** for high-performance workloads
- **Kernel compatibility** for kernels 4.15.x and above
- **Performance optimizations** for enterprise workloads

## Key Features

### Multi-Distribution Support

This operator supports building kernel modules for multiple Linux distributions:

| Node OS | Build Image | Auto-Detected |
|---------|-------------|---------------|
| Ubuntu / Debian | `ubuntu:22.04` | Yes |
| Rocky Linux 9 / RHEL 9 / Alma 9 | `rockylinux:9` | Yes |
| Rocky Linux 8 / RHEL 8 / CentOS 8 | `rockylinux:8` | Yes |
| Fedora | `fedora:latest` | Yes |
| SUSE / openSUSE | `opensuse/leap` | Yes |
| Flatcar / CoreOS / Talos | `fedora:latest` | Yes |

### Automatic Build Image Detection

The operator automatically detects your cluster's node OS and selects the appropriate build image:

```bash
# Check what build image will be used
make detect-build-image

# Show all configuration
make show-config
```

### Kernel Compatibility Validation

The build process validates that the build image matches your target kernel, failing early with a clear error message if there's a mismatch (e.g., trying to build Ubuntu kernel modules with a Rocky Linux image).

### Additional Features

- **Automatic kernel module building and loading**
- **Multi-node deployment via DaemonSet**
- **Node preparation scripts** for production NFS systems (rolling updates)
- **Secure boot support**
- **Build-only mode** (push to registry without deploying)
- **Comprehensive verification**
- **Clean uninstallation**

## Prerequisites

### Required Tools
- `kubectl` CLI tool
- `kustomize` (automatically installed if missing)
- Kubernetes cluster (1.25+) with upstream KMM operator installed
- Cluster admin privileges
- **External container registry** (Harbor, Docker Hub, Quay.io, etc.)

### Supported Kubernetes Distributions
- Vanilla Kubernetes
- Rancher RKE / RKE2
- Nutanix NKP / NKE
- VMware Tanzu
- K3s / K0s
- Any Kubernetes with node access

### KMM Operator Installation

Install the upstream KMM operator:

```bash
kubectl apply -k https://github.com/kubernetes-sigs/kernel-module-management/config/default
```

For more details, see [KMM Installation Guide](https://kmm.sigs.k8s.io/documentation/install/).

## Quick Start

```bash
# Clone the repository
git clone https://github.com/vast-data/openshift-vastnfs-kmm-operator
cd openshift-vastnfs-kmm-operator

# Set required environment variables
export VASTNFS_VERSION=4.5.5
export KMM_IMG_REPO=myregistry:5000/vastnfs

# Build kernel module image (auto-detects build image, no deployment)
make build-only

# Prepare nodes (unload in-tree NFS modules) - required for vanilla K8s
make prepare-workers

# Install VAST NFS kernel modules
make install

# Verify deployment
make verify

# Uninstall (automatic graceful cleanup)
make uninstall
```

**Important:** Unlike OpenShift, vanilla Kubernetes nodes typically have in-tree NFS modules loaded. You must run `make prepare-worker` or `make prepare-workers` to unload them before VAST NFS can be loaded.

## Installation Methods

### 1. Build Only (Recommended First Step)

Build the kernel module image without deploying to nodes:

```bash
# Auto-detects build image from cluster node OS
make build-only VASTNFS_VERSION=4.5.5 KMM_IMG_REPO=myregistry:5000/vastnfs
```

This will:
1. Build kernel module images for all cluster kernels
2. Push images to your registry
3. **Not** deploy modules to any nodes
4. Clean up automatically after builds complete

**Force Rebuild:** To force a rebuild even if images already exist:

```bash
# Force rebuild - clears registry tags and node caches
make build-only VASTNFS_VERSION=4.5.5 KMM_IMG_REPO=myregistry:5000/vastnfs FORCE=true
```

The `FORCE=true` option will:
- Delete existing image tags from the registry (if registry supports deletion)
- Clear cached images from all cluster nodes (using crictl/ctr/docker)
- Force KMM to rebuild and push fresh images

### 2. Node Preparation (Required for Vanilla Kubernetes)

Prepare nodes by unloading in-tree NFS modules:

```bash
# Prepare a single worker node
make prepare-worker NODE=worker-1

# Prepare all worker nodes (rolling update, one at a time)
make prepare-workers
```

### 3. Standard Installation

**Installation with real-time log monitoring:**
```bash
export VASTNFS_VERSION=4.5.5
export KMM_IMG_REPO=myregistry:5000/vastnfs

make install

# Wait 1-2 minutes for DaemonSet deployment, then verify
make verify
```

### 4. Secure Boot Installation

`make install-secure-boot` is the single Secure Boot entry point. Vanilla still requires
`VASTNFS_VERSION` and `KMM_IMG_REPO`.

**Generated or reused local keys:**
```bash
export VASTNFS_VERSION=4.5.5
export KMM_IMG_REPO=myregistry:5000/vastnfs

make install-secure-boot
```

**Existing enterprise-managed keys:**
```bash
export VASTNFS_VERSION=4.5.5
export KMM_IMG_REPO=myregistry:5000/vastnfs

make install-secure-boot \
  PRIVATE_KEY_FILE=/path/to/private.key \
  PUBLIC_CERT_FILE=/path/to/public.der
```

### 5. Custom Build Image

The build image is automatically selected based on each node's kernel type. KMM uses the appropriate build image for each kernel:

| Kernel Type | Build Image |
|-------------|-------------|
| Ubuntu/Debian (`-generic`, `-lowlatency`, `-aws`, etc.) | `ubuntu:22.04` |
| RHEL 9/Rocky 9/Alma 9 (`.el9`) | `rockylinux:9` |
| RHEL 8/Rocky 8/CentOS 8 (`.el8`) | `rockylinux:8` |
| Fedora (`.fc*`) | `fedora:latest` |
| SUSE/openSUSE (`-default`) | `opensuse/leap` |

This is handled automatically by KMM's kernel mapping in the Module CRD.

### 6. Manual Manifest Generation

For fine-grained control over resources, generate and customize manifests:

```bash
# Generate consolidated manifest
make build-installer

# Review and customize the generated manifest
vi dist/install.yaml

# Apply manually
kubectl apply -f dist/install.yaml
```

## Upgrading VAST NFS Version

Upgrading is fully automatic! Simply run `make install` with the new version:

```bash
# Upgrade to a new version (automatic graceful unload if already installed)
export VASTNFS_VERSION=4.5.5
make install

# Wait 1-2 minutes for rebuild and deployment, then verify
make verify
```

### How Upgrades Work

- `make install` automatically detects if VAST NFS is already loaded
- If loaded (upgrade scenario): automatically performs graceful unload first
- If not loaded (fresh install): proceeds directly with installation
- Graceful unload unmounts NFS filesystems, stops services, and cleanly unloads modules
- This prevents "module in use" errors during upgrades

The operator includes the VAST NFS version in the container image tag:
```
myregistry:5000/vastnfs:${KERNEL_FULL_VERSION}-vastnfs-${VASTNFS_VERSION}
```

For example:
- **Version 4.0.35**: `5.14.0-570.33.1.el9_6.x86_64-vastnfs-4.0.35`
- **Version 4.0.36**: `5.14.0-570.33.1.el9_6.x86_64-vastnfs-4.0.36`

This ensures that:
1. KMM detects the version change and triggers a rebuild
2. A new container image is built with the updated VAST NFS version
3. KMM rolls out the new modules to all matching nodes
4. The old modules are unloaded and new ones loaded automatically

### Uninstallation

Execute the following command to uninstall VAST NFS:

```bash
make uninstall
```

The `uninstall` target automatically:
- Gracefully unloads VAST NFS modules from all nodes
- Unmounts all NFS filesystems
- Stops RPC services cleanly
- Unloads kernel modules in the correct order
- Removes all KMM resources (Module, ConfigMaps, ServiceAccounts, etc.)
- Cleans up ImageStreams

No manual steps required!

## Usage

### Available Make Targets

#### Core Installation

| Target | Description |
|--------|-------------|
| `make build-only` | Build kernel module images and push to registry (no deployment) |
| `make build-only FORCE=true` | Force rebuild - clears registry and node caches first |
| `make install` | Install or upgrade VAST NFS (auto-detects and handles graceful unload) |
| `make reinstall` | Reinstall when VAST NFS is already loaded (skips in-tree module removal) |
| `make uninstall` | Complete removal (automatically performs graceful unload first) |
| `make uninstall-all` | Complete removal including the namespace |

#### Node Preparation (Rolling Updates)

| Target | Description |
|--------|-------------|
| `make prepare-worker NODE=<name>` | Prepare a single worker node (drain, unload NFS, load VAST NFS) |
| `make prepare-worker NODE=<name> LABEL_SKIP=true` | Prepare node and mark it to skip future KMM deployments |
| `make prepare-workers` | Prepare all worker nodes (rolling update, one at a time) |
| `make install-systemd-unit` | Install systemd unit to prevent in-tree NFS on boot (for immutable OS) |

#### Node Selection & Labeling

| Target | Description |
|--------|-------------|
| `make add-node-to-kmm NODE=<name>` | Include a node in KMM module deployment |
| `make remove-node-from-kmm NODE=<name>` | Exclude a node from KMM module deployment |
| `make show-node-labels` | Show KMM deployment status for all nodes |
| `make delete-module` | Delete Module and worker pods (keeps built images in registry) |

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
| `make install-secure-boot` | Resumable Secure Boot installation, key handling, MOK staging, and signed deployment |
| `make generate-secure-boot-keys` | Optional helper to generate secure boot signing keys |
| `make verify-secure-boot` | Verify Secure Boot state and module signatures on all target nodes |

#### Utilities

| Target | Description |
|--------|-------------|
| `make build-installer` | Generate consolidated manifest in `dist/install.yaml` |
| `make help` | Show all available targets |

### Build Image Auto-Detection

The operator automatically detects your cluster's node OS and selects the appropriate build image:

```bash
# Check what build image will be used
make detect-build-image

# Example output:
# Cluster node OS:     Ubuntu 22.04.3 LTS
# Cluster node kernel: 6.8.0-107-generic
# Auto-detected BUILD_IMAGE: ubuntu:22.04
```

### Node Selection

Control which nodes receive VAST NFS deployment using labels:

```bash
# Include a node in KMM deployment
make add-node-to-kmm NODE=worker-1

# Exclude a node from KMM deployment
make remove-node-from-kmm NODE=worker-1

# Show KMM deployment status for all nodes
make show-node-labels

# Install with node selector (only deploys to labeled nodes)
make install NODE_SELECTOR="vastnfs-kmm/enabled=true"
```

**Workflow for selective deployment:**
1. Prepare nodes one at a time with `make prepare-worker NODE=<name> LABEL_SKIP=true`
2. This loads VAST NFS and marks the node to skip future KMM deployments
3. KMM will not create worker pods on nodes without the `vastnfs-kmm/enabled=true` label

### Kernel Compatibility Validation

The build process validates that the build image matches your target kernel. If there's a mismatch, you'll see a clear error:

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

### Log Monitoring

All installation commands include real-time log monitoring. The build process:

1. **Waits for build pod** - Up to 60 seconds for pod to be created
2. **Waits for pod ready** - Up to 3 minutes for container to start (handles image pulling)
3. **Streams logs** - Follow real-time build logs
4. **Reports status** - Shows success/failure with next steps

**Post-Build Deployment Process:** After the build stage completes:

1. **Image Distribution** - The built kernel module image is pushed to your registry
2. **DaemonSet Creation** - KMM creates DaemonSet pods on nodes matching the kernel version
3. **Module Loading** - Each node downloads the image and runs `modprobe` to load VAST NFS modules
4. **Ready State** - Modules become active and available for NFS operations

This post-build process typically takes 1-2 minutes (2-3 minutes for secure boot scenarios).

**Example output:**
```
[STEP] Waiting for pods to start...
[SUCCESS] Found pods: vastnfs-pull-pod-f9t9h
[STEP] Following pod logs...
[INFO] === Preparing to follow logs for vastnfs-pull-pod-f9t9h ===
[INFO] Waiting for pod vastnfs-pull-pod-f9t9h to be ready...
[SUCCESS] Pod vastnfs-pull-pod-f9t9h is ready for log streaming
[INFO] Starting log stream for vastnfs-pull-pod-f9t9h...
```

## Verification

> **IMPORTANT:** After running `make install`, wait approximately **1-2 minutes** before verification. This allows time for:
> - Kernel module compilation to complete
> - DaemonSet pods to start on all cluster nodes  
> - VAST NFS kernel modules to be loaded via modprobe
>
> For secure boot installations, allow **2-3 minutes** due to additional signing time.

### Automatic Verification
```bash
# Verify all nodes
make verify

# Verify a single node
make verify NODE=worker-1

# Detailed verification with extra diagnostics
make verify VERBOSE=true
```

### Manual Verification
```bash
# Check module status
kubectl get module vastnfs -n vastnfs-kmm

# Check VAST NFS version on nodes
kubectl debug node/<node-name> -it --image=alpine -- chroot /host cat /sys/module/sunrpc/parameters/nfs_bundle_version

# Check loaded modules
kubectl debug node/<node-name> -it --image=alpine -- chroot /host lsmod | grep -E "(sunrpc|rpcrdma|nfs)"
```


## Troubleshooting

For comprehensive VAST NFS driver troubleshooting and advanced configuration, refer to the [official VAST NFS documentation](https://vastnfs.vastdata.com/docs/4.0/Intro.html).

### Common Issues

**1. Kernel/Build-Image Mismatch:**
```
ERROR: Kernel/Build-Image Mismatch Detected!
```
**Solution:** KMM automatically selects the correct build image based on each node's kernel type. If you see this error, it may indicate an issue with the kernel mapping configuration. Check:
```bash
# Check what build image should be used for each node
make detect-build-image

# View the Module configuration
kubectl get module vastnfs -n vastnfs-kmm -o yaml
```

**2. Missing kernel headers:**
```
No match for argument: kernel-devel-6.8.0-107-generic
```
**Solution:** This usually means wrong BUILD_IMAGE. Ubuntu kernels need Ubuntu build image, RHEL kernels need Rocky/RHEL build image.

**3. Installation hangs during uninstall:**
```bash
# The Makefile automatically handles finalizer removal
# If still stuck, manually remove finalizers:
kubectl patch module vastnfs -n vastnfs-kmm -p '{"metadata":{"finalizers":[]}}' --type=merge
```

**4. Log following fails:**
```bash
# Check pod status
kubectl get pods -n vastnfs-kmm

# Manual log access
kubectl logs <pod-name> -n vastnfs-kmm
```

**5. Module loading fails (in-tree NFS conflict):**
```bash
# Prepare the worker node first (unloads in-tree NFS modules)
make prepare-worker NODE=<node-name>
```

**6. KMM worker pods in CrashLoopBackOff after reinstalling Module:**
```
modprobe: FATAL: Module sunrpc is in use.
```
This happens when you delete and recreate the Module object while VAST NFS modules are still loaded and in use. The KMM worker tries to unload in-tree modules but fails because the VAST NFS modules (which replaced them) are active.

**Solutions:**
```bash
# Option 1: Use the reinstall target (recommended for testing/development)
# This automatically handles finalizers and skips in-tree module removal
make reinstall

# Option 2: Exclude already-prepared nodes from KMM management
make remove-node-from-kmm NODE=<node-name>

# Option 3: Properly unload modules before reinstalling
# (requires stopping all NFS workloads first)
make graceful-unload
make install
```

**7. Leftover helper pods from failed operations:**
```bash
# Clean up all debug/helper pods created by the scripts
make clean-debug-pods
```

**8. Secure boot issues:**
```bash
# Verify secure boot status on node
kubectl debug node/<node-name> -it --image=busybox -- chroot /host mokutil --sb-state

# Check module signatures
kubectl debug node/<node-name> -it --image=busybox -- chroot /host modinfo sunrpc | grep signature
```

**9. Verify deployment on specific node:**
```bash
# Check a single node
make verify NODE=worker-1

# Detailed verification
make verify VERBOSE=true
```

### Debug Commands

```bash
# Check all resources
kubectl get all -n vastnfs-kmm

# Check module details
kubectl describe module vastnfs -n vastnfs-kmm

# Check events
kubectl get events -n vastnfs-kmm --sort-by='.lastTimestamp'

# Check node status
kubectl get nodes
kubectl describe node <node-name>
```

## Configuration

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `VASTNFS_VERSION` | VAST NFS version (e.g., `4.5.5`) |
| `KMM_IMG_REPO` | Container registry for module images (e.g., `myregistry:5000/vastnfs`) |

### Optional Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_IMAGE` | Auto-detected | Base image for module building (auto-detected from cluster node OS) |
| `NAMESPACE` | `vastnfs-kmm` | Target namespace |
| `KMM_PULL_SECRET` | Empty | Pull secret for private registries |
| `HELPER_IMAGE` | `alpine:latest` | Image for node preparation pods |
| `NODE_SELECTOR` | Empty | Label selector to filter which nodes receive deployment (e.g., `vastnfs-kmm/enabled=true`) |
| `MAX_ATTEMPTS` | `60` | Maximum unload attempts for node preparation (each attempt ~3 seconds) |
| `LABEL_SKIP` | `false` | When `true`, removes enabled label after successful prepare-worker |

### Build Image Auto-Detection

If `BUILD_IMAGE` is not set, it's automatically detected from your cluster:

| Node OS | Auto-detected BUILD_IMAGE |
|---------|--------------------------|
| Ubuntu / Debian | `ubuntu:22.04` |
| Rocky Linux 9 / RHEL 9 / Alma 9 | `rockylinux:9` |
| Rocky Linux 8 / RHEL 8 / CentOS 8 | `rockylinux:8` |
| Fedora | `fedora:latest` |
| SUSE / openSUSE | `opensuse/leap` |

```bash
# Check auto-detection
make detect-build-image
```

### Customization Examples

```bash
# Custom namespace
export NAMESPACE=my-vastnfs
make install

# Custom version
export VASTNFS_VERSION=4.5.5
make install

# Build images for all cluster kernels (auto-selects appropriate build images)
make build-only
```

## Secure Boot Support

### One Resumable Secure Boot Flow

Vanilla secure boot uses the same target as OpenShift, with vanilla's required registry variables:

```bash
export VASTNFS_VERSION=4.5.5
export KMM_IMG_REPO=myregistry:5000/vastnfs

make install-secure-boot
```

When no key files are provided, the target reuses or generates:

```text
keys/vastnfs_signing_key.priv
keys/vastnfs_signing_key.der
```

Use existing signing material by passing both files:

```bash
make install-secure-boot \
  PRIVATE_KEY_FILE=/path/to/signing.key \
  PUBLIC_CERT_FILE=/path/to/signing.der
```

If Secure Boot nodes do not trust the cert yet, provide a one-time MOK password file:

```bash
make install-secure-boot MOK_PASSWORD_FILE=/secure/mok-password
```

The command stages the cert, verifies `mokutil --list-new`, and exits before deploying. Reboot each listed node, complete MokManager enrollment, then rerun the same `make install-secure-boot` command.

### Verification
```bash
# Verify secure boot deployment
make verify-secure-boot

# Or use regular verification
make verify
```

### Secure Boot Troubleshooting

- `Key was rejected by service`: the module was signed, but the node does not trust the signing cert. Rerun `make install-secure-boot MOK_PASSWORD_FILE=/secure/mok-password`, reboot, and complete MokManager enrollment.
- `mokutil --list-new` is empty: no enrollment is pending. Rerun `make install-secure-boot` with `MOK_PASSWORD_FILE` or `MOK_PASSWORD`.
- Cert is pending but no prompt appears: use the VM/BMC console during boot and watch for the MokManager prompt; increase `MOK_PROMPT_TIMEOUT` if needed.
- Wrong signing path: check KMM signing logs for missing `filesToSign` entries. Vanilla signs the flat `/opt/lib/modules/${KERNEL_FULL_VERSION}/extra/*.ko` layout.

## Documentation

Additional documentation is available in the `docs/` directory:

| Document | Description |
|----------|-------------|
| [Complete Setup Guide](docs/complete-setup-guide.md) | Comprehensive step-by-step installation guide |
| [OpenShift vs Vanilla Comparison](docs/openshift-vs-vanilla-comparison.md) | Comparison with the OpenShift-specific operator |

## Additional Resources

### VAST NFS Driver Documentation
For comprehensive information about the VAST NFS driver features, configuration, and troubleshooting, see the official documentation: [VAST NFS Documentation](https://vastnfs.vastdata.com/docs/4.0/Intro.html)

The documentation includes:
- **Installation methods** for different Linux distributions
- **Configuration options** including multipath setup
- **Usage examples** and mount parameters
- **Monitoring and diagnosis** tools
- **Troubleshooting guides** for common issues

### Related Projects

- [OpenShift VAST NFS KMM Operator](https://github.com/vast-data/openshift-vastnfs-kmm-operator) - OpenShift-specific version
- [Upstream KMM](https://kmm.sigs.k8s.io/) - Kernel Module Management for Kubernetes
- [KMM GitHub](https://github.com/kubernetes-sigs/kernel-module-management) - KMM source code
