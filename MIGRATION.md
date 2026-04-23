# Migration Guide

This repository is the merged successor of two previous repos:

- `openshift-vastnfs-kmm-operator` — the OpenShift-specific operator (this repo's history).
- `vanila-vastnfs-kmm-operator` — the multi-distro vanilla Kubernetes fork.

Whichever one you came from, **your existing commands keep working** — the consolidation was
designed to be 100% backward-compatible at the target/env-var level. This guide explains what
changed under the hood, when you might want to opt into the new layout, and how to run
`make migrate-from-legacy` to bring an older install in line with the unified manifest layout.

---

## TL;DR

| If you previously ran…                                                | Today you can still run…      | And optionally…                                |
| --------------------------------------------------------------------- | ----------------------------- | ---------------------------------------------- |
| `make install` against an OpenShift cluster                           | The same, unchanged.          | `make install PLATFORM=openshift` (explicit).  |
| `make build-installer KUSTOMIZE_DIR=k8s/base`                         | The same, unchanged.          | `KUSTOMIZE_DIR=k8s/overlays/openshift/base`.   |
| `kustomize build k8s/overlays/secure-boot`                            | The same, unchanged.          | `k8s/overlays/openshift/secure-boot`.          |
| `make prepare-worker NODE=n1 VASTNFS_VERSION=... KMM_IMG_REPO=...`    | The same, unchanged.          | Keep using it — vanilla-only targets now guard against accidental OCP invocation. |

Nothing is renamed, nothing is removed. The new layout is additive.

---

## What changed

### 1. Platform auto-detection

The Makefile now exposes a `PLATFORM` variable, defaulting to the output of
[`scripts/detect_platform.sh`](scripts/detect_platform.sh). It resolves to either `openshift` or
`vanilla` based on:

1. An explicit `PLATFORM` env var (highest priority),
2. The presence of the `oc` CLI + the `security.openshift.io/v1` API group, or
3. A default fallback of `vanilla`.

On OpenShift clusters this auto-detects to `openshift`, so all OCP-specific defaults
(`VASTNFS_VERSION=4.0.35`, `KMM_IMG_REPO=image-registry.openshift-image-registry.svc:5000/…`,
`KUBE_CMD=oc`) are preserved.

### 2. Unified `KUBE_CMD`

Scripts no longer hard-code `oc` or `kubectl`. They use `${KUBE_CMD}`, which defaults to `oc` on
OpenShift and `kubectl` on vanilla. Override explicitly if you like:

```bash
make verify KUBE_CMD=kubectl      # force kubectl on an OCP cluster
make install PLATFORM=openshift   # force the OCP defaults on a bare kubeconfig
```

### 3. New `k8s/` layout (with legacy aliases)

```
k8s/
├── base/                             # Legacy OCP path — re-exports overlays/openshift/base
├── overlays/
│   ├── secure-boot/                  # Legacy — re-exports openshift/secure-boot
│   ├── with-pull-secret/             # Legacy — re-exports openshift/with-pull-secret
│   ├── openshift/
│   │   ├── base/                     # Canonical OCP overlay
│   │   ├── secure-boot/
│   │   └── with-pull-secret/
│   └── vanilla/
│       ├── base/                     # Canonical vanilla overlay (multi-distro Module)
│       ├── secure-boot/
│       ├── with-pull-secret/
│       └── reinstall/
```

All legacy paths continue to resolve to the same manifests they did before (they are single-line
`kustomization.yaml` files that re-export the canonical overlays). You only need to update your
paths if you want the cleaner, platform-scoped references.

### 4. Node execution abstraction

[`scripts/node_exec.sh`](scripts/node_exec.sh) provides a single function, `node_exec`, that runs
a shell snippet on a cluster node. It prefers `oc debug node/<n> -- chroot /host` when running on
OpenShift (and `oc` is on `$PATH`), and falls back to a short-lived privileged
`kubectl run` pod with `nsenter -t 1` on vanilla. Every merged script
(`verify_deployment.sh`, `graceful_unload.sh`, `check_vastnfs_loaded.sh`, etc.) delegates to it
so there is exactly one place to audit for node-exec semantics.

### 5. New / enhanced targets

| Target                              | Notes                                                                                                                              |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `make show-config`                  | Shows the resolved platform, `KUBE_CMD`, image repo, and vanilla-specific knobs.                                                   |
| `make migrate-from-legacy`          | NEW — labels / annotates existing OCP installs with the unified labels. Dry-run by default, re-run with `APPLY=true`.              |
| `make verify` / `make verify VERBOSE=true` / `NODE=<name>` | Richer table + per-node deep-dive. The legacy summary lines are preserved at the end of the verbose run.   |
| `make clean-debug-pods`             | Cleans up leftover `oc debug` and `kubectl run` helper pods in any namespace.                                                      |
| `make delete-module`                | Deletes the Module + worker pods but keeps built images in your registry.                                                          |
| `make add-node-to-kmm` / `remove-node-from-kmm` / `show-node-labels` | Label-driven node selection (promoted from the vanilla repo).                                            |

### 6. Vanilla-only targets gate on `PLATFORM`

`prepare-worker`, `prepare-workers`, and `install-systemd-unit` refuse to run with
`PLATFORM=openshift` and print a clear `[SKIP]` message. This protects RHCOS nodes from accidental
systemd unit installations or forced in-tree NFS unloads. Set `PLATFORM=vanilla` explicitly to
override the guard.

---

## Migrating an existing OpenShift install

If you previously ran `make install` from the old `openshift-vastnfs-kmm-operator` repo, your
cluster already contains the expected objects:

- `Namespace vastnfs-kmm`
- `ServiceAccount vastnfs-kmm-sa`
- `ClusterRole vastnfs-kmm-privileged` + binding
- `ConfigMap vastnfs-kmm-build-dockerfile`
- `Module vastnfs`
- `ImageStream vastnfs`

They continue to work unchanged against the new Makefile. To align their labels/annotations with
the new manifest layout (so future `kustomize build` invocations are idempotent), run:

```bash
# Dry-run — prints the planned changes without touching the cluster
make migrate-from-legacy

# Apply the plan (safe — labels/annotations only, no Module reload)
APPLY=true make migrate-from-legacy

# Optional: also re-apply the Module manifest (may trigger a module reload)
APPLY=true ALLOW_RELOAD=true make migrate-from-legacy
```

The script:

1. Detects whether `Module/vastnfs` exists in the target namespace.
2. Prints a per-object plan showing the labels/annotations that will be added or refreshed.
3. Only mutates the cluster when `APPLY=true` is passed.
4. Never triggers a module reload unless `ALLOW_RELOAD=true` is also set.

---

## Migrating from `vanila-vastnfs-kmm-operator`

1. Clone this repository (it replaces the old one).
2. Keep using all the same targets (`prepare-worker`, `build-only`, `install`, `verify`, …). They
   work identically on this repo with `PLATFORM=vanilla` (auto-detected).
3. The `k8s/base` path from the old repo now refers to the OpenShift overlay by default; the
   vanilla equivalent lives at `k8s/overlays/vanilla/base`. If any of your tooling hard-codes
   `KUSTOMIZE_DIR=k8s/base`, either set `PLATFORM=vanilla` (which changes the default to
   `k8s/overlays/vanilla/base`) or set `KUSTOMIZE_DIR=k8s/overlays/vanilla/base` explicitly.
4. Supporting docs live in `docs/vanilla.md`, `docs/vanilla-complete-setup-guide.md`,
   `docs/nkp-vsphere-installation-guide.md`, and `docs/openshift-vs-vanilla.md`.

---

## Rollback

If something unexpected breaks, you can always pin to a pre-consolidation tag of this repo (or
the last commit of the old `vanila-vastnfs-kmm-operator`) and re-run the same commands — all
CRD objects this operator installs are compatible across versions. The merge does not change
API surface, only packaging and tooling.
