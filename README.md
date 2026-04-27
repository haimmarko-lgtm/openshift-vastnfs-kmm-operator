# VAST NFS KMM Operator

Automated deployment and lifecycle management of **VAST NFS kernel modules** on Kubernetes clusters
— both **OpenShift** and **vanilla Kubernetes** (Rancher, NKP, Tanzu, Talos, Flatcar, k3s, …) — via the
upstream [Kernel Module Management (KMM)](https://kmm.sigs.k8s.io/) operator.

This repository is the merged successor of the two historical repos:

- `openshift-vastnfs-kmm-operator` (OCP-specific)
- `vanila-vastnfs-kmm-operator` (multi-distro vanilla Kubernetes)

Both now live here as overlays of a single codebase. See [MIGRATION.md](MIGRATION.md) if you are
coming from either previous repo.

---

## Choose your platform

The Makefile auto-detects the target platform via
[`scripts/detect_platform.sh`](scripts/detect_platform.sh). You can always override with
`PLATFORM=openshift` or `PLATFORM=vanilla`.

| If your cluster is…                                          | Use                    | Follow                                   |
| ------------------------------------------------------------ | ---------------------- | ---------------------------------------- |
| **OpenShift / OKD / ROSA / ARO** (RHCOS nodes)               | `PLATFORM=openshift`   | [docs/openshift.md](docs/openshift.md)   |
| **Vanilla Kubernetes** (Ubuntu, Rocky, RHEL, Fedora, SUSE…)  | `PLATFORM=vanilla`     | [docs/vanilla.md](docs/vanilla.md)       |
| Not sure which one is right for you                          | —                      | [docs/openshift-vs-vanilla.md](docs/openshift-vs-vanilla.md) |

Useful background:

- [docs/nkp-vsphere-installation-guide.md](docs/nkp-vsphere-installation-guide.md) — Nutanix NKP on vSphere walkthrough.
- [docs/vanilla-complete-setup-guide.md](docs/vanilla-complete-setup-guide.md) — deep dive for multi-distro vanilla setups.
- [docs/discussion.md](docs/discussion.md) — archived design diary (history of the consolidation).

---

## Quick start — OpenShift

```bash
git clone https://github.com/vast-data/openshift-vastnfs-kmm-operator
cd openshift-vastnfs-kmm-operator

# PLATFORM auto-detects to "openshift" on an OCP cluster; VASTNFS_VERSION defaults to 4.0.35
# and KMM_IMG_REPO defaults to the internal registry, matching the legacy behavior.
make install

# Wait 1-2 minutes for the DaemonSet to roll out, then:
make verify
```

See [docs/openshift.md](docs/openshift.md) for the full guide, secure-boot installations, upgrades, and uninstall.

## Secure Boot In One Command

Use the same resumable target for generated keys, existing keys, MOK staging, and final deployment:

```bash
# Generate/reuse local keys, create signing secrets, and deploy when nodes trust the cert.
make install-secure-boot VASTNFS_VERSION=4.5.5

# Use existing enterprise-managed signing material.
make install-secure-boot \
  VASTNFS_VERSION=4.5.5 \
  PRIVATE_KEY_FILE=/secure/vastnfs.priv \
  PUBLIC_CERT_FILE=/secure/vastnfs.der

# If Secure Boot nodes need MOK enrollment, provide a one-time password file.
# The command stages enrollment, stops with reboot instructions, and resumes
# when rerun after MokManager confirmation.
make install-secure-boot \
  VASTNFS_VERSION=4.5.5 \
  MOK_PASSWORD_FILE=/secure/mok-password
```

## Quick start — vanilla Kubernetes

```bash
git clone https://github.com/vast-data/openshift-vastnfs-kmm-operator
cd openshift-vastnfs-kmm-operator

export VASTNFS_VERSION=4.5.5
export KMM_IMG_REPO=myregistry.example.com:5000/vastnfs

# 1) Build kernel module images for every cluster kernel (no deploy yet)
make build-only

# 2) Unload in-tree NFS on every worker (rolling update)
make prepare-workers

# 3) Install the KMM Module
make install
make verify
```

See [docs/vanilla.md](docs/vanilla.md) for the full guide, secure boot, node selection helpers,
and the rolling-update playbook.

---

## Makefile help

Use the Makefile help as the source of truth for targets and parameters:

```bash
make help
make help install
make help install-secure-boot
make help prepare-worker
```

`make help` prints the available targets. `make help <target>` prints a detailed explanation of
what that target does and what each parameter is used for.

The Makefile auto-detects `PLATFORM`, but you can always override it with
`PLATFORM=openshift` or `PLATFORM=vanilla`. Platform-specific targets, such as
`install-systemd-unit`, validate the selected platform before running.

---

## VAST NFS

VAST NFS is a high-performance NFS implementation that backports upstream v5.15.x LTS NFS code
for multipath, GDS, and compatibility on kernels 4.15+. See the
[official VAST NFS documentation](https://vastnfs.vastdata.com/docs/4.0/Intro.html) for feature
details, mount parameters, and end-user troubleshooting.

---

## Related projects

- [Upstream KMM](https://kmm.sigs.k8s.io/) — `kubernetes-sigs/kernel-module-management`.
- [VAST NFS documentation](https://vastnfs.vastdata.com/docs/4.0/Intro.html).

The `vanila-vastnfs-kmm-operator` repo is now **deprecated** and points here.
