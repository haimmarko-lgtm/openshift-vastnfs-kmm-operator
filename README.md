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

## Key Makefile targets

Run `make help` to see everything. The targets below are the most common.

| Target                                 | Works on                | Description |
| -------------------------------------- | ----------------------- | ----------- |
| `make show-config`                     | all                     | Print resolved `PLATFORM`, `KUBE_CMD`, `VASTNFS_VERSION`, `KMM_IMG_REPO`, etc. |
| `make install`                         | all                     | Install / upgrade VAST NFS; auto-detects already-loaded module and performs graceful unload first. |
| `make verify` (`VERBOSE=true`, `NODE=`) | all                     | Compact or detailed health check of every node in the cluster. |
| `make graceful-unload`                 | all                     | Cordon nodes, unmount, stop RPC, unload modules. |
| `make uninstall` / `make uninstall-all` | all                     | Remove KMM Module + RBAC; `uninstall-all` also deletes the namespace. |
| `make build-installer`                 | all                     | Render a single `dist/install.yaml` (useful for GitOps). |
| `make install-secure-boot[-with-keys]` | all                     | Secure Boot signing flow. |
| `make build-only` (`FORCE=true`)       | all (vanilla-focused)   | Build images into your registry without deploying any worker pods. |
| `make reinstall`                       | all                     | Re-apply the Module while VAST NFS is already loaded (skips in-tree removal). |
| `make prepare-worker NODE=<name>`      | **vanilla only**        | Drain a node, unload in-tree NFS, let KMM load VAST NFS. |
| `make prepare-workers`                 | **vanilla only**        | Same as above, but rolling across all workers. |
| `make install-systemd-unit`            | **vanilla only**        | Install a systemd unit on every node blocking in-tree NFS at boot. |
| `make add-node-to-kmm NODE=<name>` / `remove-node-from-kmm` | all | Manage the `vastnfs-kmm/enabled` label + Module selector. |
| `make show-node-labels`                | all                     | Print the `vastnfs-kmm/enabled` label status for every node. |
| `make clean-debug-pods`                | all                     | Clean up any leftover helper/debug pods. |
| `make migrate-from-legacy`             | OCP migrations          | Label/annotate existing OCP objects for the unified manifest layout (see [MIGRATION.md](MIGRATION.md)). |

Vanilla-only targets refuse to run on OpenShift with a `[SKIP]` message; set `PLATFORM=vanilla`
explicitly if you really need to bypass the guard.

---

## Repository layout

```
├── Makefile                     # Single, platform-aware dispatcher
├── scripts/
│   ├── detect_platform.sh       # openshift|vanilla auto-detection
│   ├── node_exec.sh             # oc debug vs. kubectl-run + nsenter abstraction
│   ├── common.sh                # shared helpers (PLATFORM / KUBE_CMD aware)
│   ├── install_and_follow_logs.sh
│   ├── install_with_secure_boot.sh
│   ├── verify_deployment.sh
│   ├── graceful_unload.sh
│   ├── check_vastnfs_loaded.sh
│   ├── generate_secure_boot_keys.sh
│   ├── migrate_from_legacy.sh   # NEW: re-label existing OCP installs
│   ├── prepare_node_for_vastnfs.sh    # vanilla
│   ├── prepare_all_workers.sh         # vanilla
│   ├── build_only_monitor.sh          # vanilla
│   ├── force_clear_images.sh          # vanilla
│   ├── install_systemd_unit.sh        # vanilla
│   └── detect_build_image.sh          # vanilla
├── k8s/
│   ├── base/                    # Thin re-export of overlays/openshift/base (legacy OCP path)
│   └── overlays/
│       ├── openshift/{base,secure-boot,with-pull-secret}
│       ├── vanilla/{base,secure-boot,with-pull-secret,reinstall}
│       ├── secure-boot/         # Legacy alias → openshift/secure-boot
│       └── with-pull-secret/    # Legacy alias → openshift/with-pull-secret
├── systemd/                     # disable-intree-nfs.service (vanilla helper)
└── docs/                        # Platform guides + design archive
```

Backward compatibility: every historical OpenShift path (`k8s/base`, `k8s/overlays/secure-boot`,
`k8s/overlays/with-pull-secret`) continues to resolve to the same OpenShift manifests via thin
`kustomization.yaml` re-exports. Existing CI, GitOps pipelines, and `oc apply -k` invocations do
not need to change.

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
