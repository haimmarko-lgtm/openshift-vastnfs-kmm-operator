# OpenShift vs Vanilla Kubernetes: VAST NFS KMM Operator Comparison

This document compares the OpenShift and vanilla Kubernetes modes in the unified
[vast-data/openshift-vastnfs-kmm-operator](https://github.com/vast-data/openshift-vastnfs-kmm-operator)
repository.

Both modes deploy VAST NFS kernel modules using KMM, but they target different Kubernetes distributions and have different architectural approaches.

## Quick Comparison Table

| Feature | OpenShift Operator | Vanilla Kubernetes Operator |
|---------|-------------------|----------------------------|
| **Target Platform** | OpenShift (4.12+) | Any Kubernetes (with upstream KMM) |
| **KMM Source** | OpenShift KMM (OperatorHub) | Upstream KMM ([kmm.sigs.k8s.io](https://kmm.sigs.k8s.io/)) |
| **Build Image** | `DTK_AUTO` (Driver Toolkit) | Auto-detected or user-specified |
| **Build Image Auto-Detection** | N/A (DTK handles it) | Yes (detects from cluster node OS) |
| **Kernel Compatibility Validation** | N/A (DTK guarantees it) | Yes (fails early with clear error) |
| **Container Registry** | OpenShift internal registry | User-provided external registry (required) |
| **Node OS Support** | RHEL CoreOS only | Ubuntu, Debian, RHEL, CentOS, Rocky, Fedora, SUSE, immutable OS |
| **Node Preparation** | Not handled | Drain + unload in-tree NFS |
| **Kernel Headers** | Pre-installed in DTK | Downloaded during build |
| **Build Complexity** | Simple (pre-configured) | Automated (multi-distro detection) |
| **Setup Time** | ~5 minutes | ~15-30 minutes |
| **External Dependencies** | None (all OpenShift native) | External container registry required |
| **Immutable OS Support** | Native (CoreOS) | Supported with systemd unit |
| **Secure Boot** | Supported | Supported |
| **CLI Tool** | `oc` (OpenShift CLI) | `kubectl` |

## Detailed Comparison

### 1. Target Platform & KMM Source

#### OpenShift Operator
- **Platform**: OpenShift Container Platform 4.12+
- **KMM**: OpenShift KMM operator installed via OperatorHub
- **Integration**: Native OpenShift integration with ImageStreams, internal registry

```bash
# KMM installation on OpenShift
# Install via OperatorHub UI or:
oc apply -f kmm-operator-subscription.yaml
```

#### Vanilla Kubernetes Operator
- **Platform**: Any Kubernetes cluster (1.25+) - Requires per system validation 
- **KMM**: Upstream KMM from [kmm.sigs.k8s.io](https://kmm.sigs.k8s.io/)

```bash
# KMM installation on vanilla Kubernetes
kubectl apply -k https://github.com/kubernetes-sigs/kernel-module-management/config/default
```

### 2. Build Image Strategy

#### OpenShift Operator - DTK_AUTO

The OpenShift operator uses `DTK_AUTO` (Driver Toolkit Auto), a special KMM feature:

```dockerfile
ARG DTK_AUTO
FROM ${DTK_AUTO} as builder
```

**How DTK_AUTO works:**
- KMM automatically resolves `DTK_AUTO` to the correct Red Hat Driver Toolkit image
- The DTK image matches the node's kernel version exactly
- All build tools are pre-installed (gcc, make, kernel headers, etc.)
- No package installation needed during build

**Advantages:**
- Guaranteed kernel header compatibility
- Fast builds (no package downloads)
- Simple Dockerfile

**Limitations:**
- Only works on OpenShift
- Only supports RHEL/CoreOS nodes

#### Vanilla Kubernetes Operator - Auto-Detected Build Images

The vanilla operator automatically detects the appropriate build image from your cluster's node OS:

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

**Kernel Compatibility Validation:**

The build process validates that the build image matches the target kernel. If there's a mismatch, it fails early with a clear error:

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

**How the build works:**
1. Auto-detects node OS (or uses user-specified BUILD_IMAGE)
2. Validates kernel/build-image compatibility
3. Detects the package manager (apt, dnf, yum, zypper)
4. Installs build dependencies
5. Downloads kernel headers matching the target kernel
6. Builds the kernel modules

**Advantages:**
- Works with any node OS
- Auto-detects correct build image
- Early validation prevents confusing errors
- Flexible distribution support
- No OpenShift dependency

**Limitations:**
- Longer build times (package installation)
- Requires external container registry

### 3. Container Registry

#### OpenShift Operator
Uses the built-in OpenShift internal registry:

```
image-registry.openshift-image-registry.svc:5000/vastnfs-kmm/vastnfs
```

**Advantages:**
- No external registry needed
- Automatic authentication via ServiceAccount
- Native integration with OpenShift

#### Vanilla Kubernetes Operator
Requires a user-provided external registry:

```bash
export KMM_IMG_REPO=myregistry.example.com:5000/vastnfs
make install
```

**Considerations:**
- Must be accessible from all cluster nodes
- May require pull secrets for authentication
- User manages registry lifecycle

### 4. Node Preparation

#### OpenShift Operator
**Currently not identifing in-tree NFS modules conflicts.**

Current implementation does not check for conflicting in-tree NFS modules; in such cases, the VAST NFS module load will fail.

#### Vanilla Kubernetes Operator
**Node preparation is required** to unload in-tree NFS modules before loading VAST NFS:

```bash
# Prepare a single worker node
make prepare-worker NODE=worker-1

# Prepare all worker nodes (rolling update)
make prepare-workers
```

**The preparation process:**
1. Cordons the node
2. Drains all pods
3. Iteratively unloads all NFS modules
4. Uncordons for KMM deployment

**For immutable OS :**
```bash
make install-systemd-unit
```

### 5. Build Process Comparison

#### OpenShift Build (Simple)

```dockerfile
# Install minimal extra tools
RUN dnf install -y xz tar findutils rpm-build make gcc && dnf clean all

# Download and build
RUN curl -sSf https://vast-nfs.s3.amazonaws.com/download.sh | bash -s -- --source --version ${VASTNFS_VERSION}
RUN tar -xf vastnfs-*.tar.xz && cd vastnfs-${VASTNFS_VERSION} && ./build.sh bin --no-ofed
```

#### Vanilla Kubernetes Build (Complex)

```dockerfile
# Detect package manager and install dependencies
RUN if command -v apt-get >/dev/null 2>&1; then \
        apt-get update && apt-get install -y build-essential curl xz-utils tar kmod python3 ... \
    elif command -v dnf >/dev/null 2>&1; then \
        dnf install -y gcc make curl xz tar kmod python3 which rpm-build ... \
    elif command -v yum >/dev/null 2>&1; then \
        yum install -y gcc make curl xz tar kmod python3 which rpm-build ... \
    elif command -v zypper >/dev/null 2>&1; then \
        zypper --non-interactive install gcc make curl xz tar kmod python3 which ... \
    fi

# Download and build
RUN curl -sSf https://vast-nfs.s3.amazonaws.com/download.sh | bash -s -- --source --version ${VASTNFS_VERSION}
RUN tar -xf vastnfs-*.tar.xz && cd vastnfs-${VASTNFS_VERSION} && ./build.sh bin --no-ofed
```

## Pros and Cons

### OpenShift Operator

| Pros | Cons |
|------|------|
| Simple setup (~5 minutes) | OpenShift only |
| No external registry needed | RHEL/CoreOS nodes only |
| DTK guarantees kernel compatibility | Requires OpenShift subscription |
| Native OpenShift integration | No multi-distro support |
| Faster builds | Tied to Red Hat ecosystem |
| Zero configuration needed | No node preparation handling |

### Vanilla Kubernetes Operator

| Pros | Cons |
|------|------|
| Works on any Kubernetes | Requires external registry |
| Supports multiple node OS | Initial setup takes longer (~15-30 min) |
| Auto-detects correct build image | Node preparation required for production |
| Validates kernel/build-image compatibility | Longer build times (package installation) |
| Early failure with clear error messages | |
| No OpenShift dependency | |
| Works with managed K8s (EKS, AKS, GKE) | |
| Production NFS rolling updates | |
| Open source KMM | |
| Configuration inspection tools | |

## Feature Matrix

| Feature | OpenShift | Vanilla |
|---------|:---------:|:-------:|
| Automatic kernel module building | ✅ | ✅ |
| Multi-node deployment (DaemonSet) | ✅ | ✅ |
| Secure boot support | ✅ | ✅ |
| Version upgrades | ✅ | ✅ |
| Graceful unload | ✅ | ✅ |
| Real-time log monitoring | ✅ | ✅ |
| Build image auto-detection | N/A (DTK) | ✅ |
| Kernel compatibility validation | N/A (DTK) | ✅ |
| Build-only mode (no deploy) | ❌ | ✅ |
| Node preparation scripts | ❌ | ✅ |
| Rolling node updates | ❌ | ✅ |
| Multi-distro node support | ❌ | ✅ |
| External registry support | ❌ | ✅ |
| Immutable OS systemd unit | N/A (native) | ✅ |
| Configuration inspection (`show-config`) | ❌ | ✅ |
| Internal registry support | ✅ | ❌ |
| Zero-config setup | ✅ | ❌ |

## References

- [OpenShift VAST NFS KMM Operator](https://github.com/vast-data/openshift-vastnfs-kmm-operator)
- [Upstream KMM Documentation](https://kmm.sigs.k8s.io/)
- [VAST NFS Documentation](https://vastnfs.vastdata.com/docs/4.0/Intro.html)
- [OpenShift KMM Documentation](https://docs.openshift.com/container-platform/latest/hardware_enablement/kmm-kernel-module-management.html)
