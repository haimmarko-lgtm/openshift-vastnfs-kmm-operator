.EXPORT_ALL_VARIABLES:
SHELL := /usr/bin/env bash
CURRENT_TARGET := $(firstword $(MAKECMDGOALS))

######################
# PLATFORM SELECTION
######################
# PLATFORM: one of "openshift" or "vanilla".
#   - Defaults to the result of scripts/detect_platform.sh.
#   - Override explicitly via: make <target> PLATFORM=vanilla
#
# Backward compatibility: existing OpenShift CI/scripts continue to work
# unchanged because PLATFORM auto-detects to "openshift" on OCP clusters.
ifndef PLATFORM
PLATFORM := $(shell ./scripts/detect_platform.sh 2>/dev/null || echo vanilla)
endif

# KUBE_CMD: the Kubernetes CLI to use. Prefer `oc` on OpenShift when it is
# installed, but fall back to `kubectl` so OpenShift-compatible flows still work
# on hosts that only have kubectl. Vanilla defaults to kubectl.
ifeq ($(PLATFORM),openshift)
    KUBE_CMD ?= $(shell if command -v oc >/dev/null 2>&1; then echo oc; elif command -v kubectl >/dev/null 2>&1; then echo kubectl; else echo oc; fi)
else
    KUBE_CMD ?= kubectl
endif

######################
# CORE CONFIGURATION
######################
# VASTNFS_VERSION:
#   - OpenShift keeps the historical default (4.0.35) for CI compatibility.
#   - Vanilla requires an explicit version (errors via check_required_env).
ifeq ($(PLATFORM),openshift)
VASTNFS_VERSION ?= 4.0.35
else
VASTNFS_VERSION ?=
endif

NAMESPACE ?= vastnfs-kmm

# KUSTOMIZE_DIR:
#   - Legacy default on OpenShift was "k8s/base" (which is now a thin
#     re-export of k8s/overlays/openshift/base, preserving that path).
#   - New canonical default points at the platform overlay directly.
ifeq ($(PLATFORM),openshift)
KUSTOMIZE_DIR ?= k8s/base
else
KUSTOMIZE_DIR ?= k8s/overlays/vanilla/base
endif

######################
# KMM IMAGE CONFIGURATION
######################
# OpenShift: default to the in-cluster image registry (legacy behavior).
# Vanilla:   user must supply an external registry (no default).
ifeq ($(PLATFORM),openshift)
KMM_IMG_REPO ?= image-registry.openshift-image-registry.svc:5000/vastnfs-kmm/vastnfs
else
KMM_IMG_REPO ?=
endif
KMM_IMG_TAG ?= \$${KERNEL_FULL_VERSION}-vastnfs-$(VASTNFS_VERSION)
KMM_PULL_SECRET ?=

######################
# NODE SELECTION (vanilla-flavored; harmless on OCP)
######################
# NODE_SELECTOR: optional Module.spec.selector patch, e.g. "vastnfs-kmm/enabled=true"
NODE_SELECTOR ?=
SECURE_BOOT_KUSTOMIZE_DIR ?= k8s/overlays/$(PLATFORM)/secure-boot
SECURE_BOOT_KMM_IMG_TAG ?= $(KMM_IMG_TAG)-secureboot

######################
# BUILD IMAGE AUTO-DETECT (vanilla only)
######################
# On vanilla, detect the preferred build base image from cluster nodes.
# On OpenShift we use the DTK and leave BUILD_IMAGE unset (harmless).
ifeq ($(PLATFORM),vanilla)
ifndef BUILD_IMAGE
BUILD_IMAGE := $(shell ./scripts/detect_build_image.sh 2>/dev/null || echo ubuntu:22.04)
endif
endif

# Helper image for node preparation / nsenter pods (vanilla only).
HELPER_IMAGE ?= alpine:latest

######################
# TOOLING
######################
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

KUSTOMIZE ?= $(LOCALBIN)/kustomize
KUSTOMIZE_VERSION ?= v5.4.3

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m)
ifeq ($(ARCH),x86_64)
	ARCH := amd64
endif
ifeq ($(ARCH),aarch64)
	ARCH := arm64
endif
ifeq ($(ARCH),arm64)
	ARCH := arm64
endif
ifeq ($(ARCH),i386)
	ARCH := 386
endif
ifeq ($(ARCH),i686)
	ARCH := 386
endif
ifeq ($(OS),darwin)
	OS := darwin
endif

define check_required_env =
	@if [ -n "$$CURRENT_TARGET" ]; then \
		printf "\033[32m[%s]\033[0m\n" "$$CURRENT_TARGET"; \
	fi; \
	missing_vars=0; \
	for var in $(strip $1); do \
		if [ -z "$${!var}" ]; then \
			printf "\033[31m!\033[36m%-30s\033[0m \033[31m<missing>\033[0m\n" $$var; \
			missing_vars=1; \
		else \
			printf "\033[31m!\033[36m%-30s\033[0m %s\n" $$var "$${!var}"; \
		fi; \
	done; \
	if [ $$missing_vars -ne 0 ]; then \
		echo "Please ensure all required environment variables are set and not empty."; \
		exit 1; \
	fi;
endef

# Gate a target to a specific platform (prints a friendly warning and exits 1
# when PLATFORM doesn't match the supplied value). Collapsed to a single
# line so it works reliably inside recipes via $(call).
define require_platform
@if [ "$(PLATFORM)" != "$(1)" ]; then echo "[SKIP] Target '$$CURRENT_TARGET' is only meaningful on PLATFORM=$(1). Current PLATFORM=$(PLATFORM). Set PLATFORM=$(1) explicitly to force."; exit 1; fi
endef

# Resolve the pull-secret overlay path, preferring the new layout
# (KUSTOMIZE_DIR/../with-pull-secret) and falling back to the legacy
# layout (KUSTOMIZE_DIR/../overlays/with-pull-secret) for OCP-era callers.
# Collapsed to one logical line so it expands cleanly inside recipes.
resolve_pull_secret_dir = if [ -d "$(KUSTOMIZE_DIR)/../with-pull-secret" ]; then __PS_DIR="$(KUSTOMIZE_DIR)/../with-pull-secret"; elif [ -d "$(KUSTOMIZE_DIR)/../overlays/with-pull-secret" ]; then __PS_DIR="$(KUSTOMIZE_DIR)/../overlays/with-pull-secret"; else __PS_DIR=""; fi

######################
# REQUIRED-ENV HELPERS
######################
# check_required_env var set differs between platforms (vanilla additionally
# requires KMM_IMG_REPO because it has no default).
ifeq ($(PLATFORM),openshift)
REQ_INSTALL_ENV := VASTNFS_VERSION NAMESPACE
else
REQ_INSTALL_ENV := VASTNFS_VERSION KMM_IMG_REPO NAMESPACE
endif

HELP_TOPIC := $(if $(filter help,$(firstword $(MAKECMDGOALS))),$(word 2,$(MAKECMDGOALS)))
HELP_TOPIC_GOALS := $(filter-out help,$(if $(filter help,$(firstword $(MAKECMDGOALS))),$(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))))

.PHONY: help

ifneq ($(HELP_TOPIC),)
.PHONY: $(HELP_TOPIC_GOALS)
$(HELP_TOPIC_GOALS):
	@:
endif

ifeq ($(HELP_TOPIC),)

.PHONY: check_required_env

######################
# DEPENDENCIES
######################
.PHONY: kustomize install-kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
install-kustomize: kustomize ## Alias for kustomize target
$(KUSTOMIZE): $(LOCALBIN)
	@echo "Installing kustomize $(KUSTOMIZE_VERSION) for $(OS)/$(ARCH) to $(LOCALBIN)..."
	@mkdir -p $(LOCALBIN)
	@curl -fsSL https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$(KUSTOMIZE_VERSION)/kustomize_$(KUSTOMIZE_VERSION)_$(OS)_$(ARCH).tar.gz | tar -xzC $(LOCALBIN)
	@chmod +x $(KUSTOMIZE)
	@echo "Kustomize installed successfully: $(KUSTOMIZE)"

######################
# NAMESPACE MANAGEMENT
######################
create-namespace: ## Create namespace for VAST NFS KMM
	@if ! $(KUBE_CMD) get namespace $(NAMESPACE) > /dev/null 2>&1; then \
		echo "Namespace $(NAMESPACE) does not exist. Creating it..."; \
		$(KUBE_CMD) create namespace $(NAMESPACE); \
	else \
		echo "Namespace $(NAMESPACE) already exists."; \
	fi

######################
# BUILD TARGETS
######################
build-installer: kustomize ## Generate a consolidated YAML with CRDs and deployment
	@$(call check_required_env,$(REQ_INSTALL_ENV))
	@mkdir -p dist
	@export VASTNFS_VERSION="$(VASTNFS_VERSION)"; \
	export KMM_IMG="$(KMM_IMG_REPO):$(KMM_IMG_TAG)"; \
	export NAMESPACE="$(NAMESPACE)"; \
	export KMM_PULL_SECRET="$(KMM_PULL_SECRET)"; \
	$(resolve_pull_secret_dir); \
	if [ -n "$$KMM_PULL_SECRET" ] && [ -n "$$__PS_DIR" ]; then \
		echo "Building with pull secret overlay: $$KMM_PULL_SECRET ($$__PS_DIR)"; \
		$(KUSTOMIZE) build "$$__PS_DIR" | envsubst '$$VASTNFS_VERSION $$KMM_IMG $$NAMESPACE $$KMM_PULL_SECRET' > dist/install.yaml; \
	else \
		echo "Building base configuration ($(KUSTOMIZE_DIR), platform=$(PLATFORM))"; \
		$(KUSTOMIZE) build $(KUSTOMIZE_DIR) | envsubst '$$VASTNFS_VERSION $$KMM_IMG $$NAMESPACE' > dist/install.yaml; \
	fi
	@echo "Generated consolidated manifest at dist/install.yaml"

######################
# BUILD-ONLY (vanilla-focused; builds images without deploying)
######################
FORCE ?= false

build-only: create-namespace kustomize ## Build kernel module images without deploying (FORCE=true to rebuild)
	@$(call check_required_env,VASTNFS_VERSION KMM_IMG_REPO NAMESPACE)
	@echo ""
	@if [ "$(FORCE)" = "true" ]; then \
		echo "================================================================="; \
		echo "  BUILD-ONLY Mode: FORCED Rebuild (clearing caches)"; \
		echo "================================================================="; \
	else \
		echo "================================================================="; \
		echo "  BUILD-ONLY Mode: Building Images Without Deployment"; \
		echo "================================================================="; \
	fi
	@echo "VAST NFS Version: $(VASTNFS_VERSION)"
	@echo "Registry:         $(KMM_IMG_REPO)"
	@echo "Platform:         $(PLATFORM)"
	@echo ""
	@echo "[INFO] Cleaning up existing Module (if any)..."
	@$(KUBE_CMD) patch module vastnfs -n $(NAMESPACE) -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
	@$(KUBE_CMD) delete module vastnfs -n $(NAMESPACE) --ignore-not-found=true --wait=false 2>/dev/null || true
	@$(KUBE_CMD) wait --for=delete module/vastnfs -n $(NAMESPACE) --timeout=30s 2>/dev/null || true
	@$(KUBE_CMD) delete pods -n $(NAMESPACE) -l kmm.node.kubernetes.io/module.name=vastnfs --ignore-not-found=true 2>/dev/null || true
	@$(KUBE_CMD) patch moduleimagesconfig vastnfs -n $(NAMESPACE) -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
	@$(KUBE_CMD) delete moduleimagesconfig vastnfs -n $(NAMESPACE) --ignore-not-found=true 2>/dev/null || true
	@sleep 2
	@if [ "$(FORCE)" = "true" ]; then \
		echo "[FORCE] Clearing existing images..."; \
		NAMESPACE=$(NAMESPACE) KUBE_CMD=$(KUBE_CMD) ./scripts/force_clear_images.sh "$(KMM_IMG_REPO)" "$(VASTNFS_VERSION)" "$(HELPER_IMAGE)"; \
	fi
	@export VASTNFS_VERSION="$(VASTNFS_VERSION)"; \
	export KMM_IMG="$(KMM_IMG_REPO):$(KMM_IMG_TAG)"; \
	export NAMESPACE="$(NAMESPACE)"; \
	export KMM_PULL_SECRET="$(KMM_PULL_SECRET)"; \
	$(resolve_pull_secret_dir); \
	if [ -n "$$KMM_PULL_SECRET" ] && [ -n "$$__PS_DIR" ]; then \
		$(KUSTOMIZE) build "$$__PS_DIR" | envsubst '$$VASTNFS_VERSION $$KMM_IMG $$NAMESPACE $$KMM_PULL_SECRET' | $(KUBE_CMD) apply -f -; \
	else \
		$(KUSTOMIZE) build $(KUSTOMIZE_DIR) | envsubst '$$VASTNFS_VERSION $$KMM_IMG $$NAMESPACE' | $(KUBE_CMD) apply -f -; \
	fi
	@echo ""
	@echo "[INFO] Waiting for KMM to process (builds or existing images)..."
	@sleep 5
	@echo "[INFO] Monitoring builds and preventing worker pod deployment..."
	@NAMESPACE=$(NAMESPACE) KUBE_CMD=$(KUBE_CMD) ./scripts/build_only_monitor.sh $(NAMESPACE) $(VASTNFS_VERSION) $(KMM_IMG_REPO)

######################
# INSTALLATION TARGETS
######################
install: create-namespace kustomize ## Install VAST NFS KMM on the cluster with log monitoring
	@$(call check_required_env,$(REQ_INSTALL_ENV))
	@NAMESPACE=$(NAMESPACE) KUBE_CMD=$(KUBE_CMD) PLATFORM=$(PLATFORM) NODE_SELECTOR="$(NODE_SELECTOR)" \
		VASTNFS_VERSION="$(VASTNFS_VERSION)" ALLOW_UNSIGNED_ON_SECURE_BOOT="$(ALLOW_UNSIGNED_ON_SECURE_BOOT)" \
		./scripts/check_secure_boot_required.sh
	@echo "Checking if VAST NFS is already loaded (for upgrade scenario)..."
	@if NAMESPACE=$(NAMESPACE) KUBE_CMD=$(KUBE_CMD) PLATFORM=$(PLATFORM) ./scripts/check_vastnfs_loaded.sh 2>/dev/null; then \
		echo "VAST NFS is already loaded - performing graceful unload before upgrade..."; \
		$(MAKE) graceful-unload; \
	else \
		echo "VAST NFS not currently loaded - proceeding with fresh installation..."; \
	fi
	@export VASTNFS_VERSION="$(VASTNFS_VERSION)"; \
	export KMM_IMG="$(KMM_IMG_REPO):$(KMM_IMG_TAG)"; \
	export NAMESPACE="$(NAMESPACE)"; \
	export KMM_PULL_SECRET="$(KMM_PULL_SECRET)"; \
	export BUILD_IMAGE="$(BUILD_IMAGE)"; \
	export KUSTOMIZE_DIR="$(KUSTOMIZE_DIR)"; \
	export KUSTOMIZE="$(KUSTOMIZE)"; \
	export NODE_SELECTOR="$(NODE_SELECTOR)"; \
	export PLATFORM="$(PLATFORM)"; \
	export KUBE_CMD="$(KUBE_CMD)"; \
	./scripts/install_and_follow_logs.sh --follow-logs

graceful-unload: ## Cordons nodes and gracefully unloads VAST NFS modules (FORCE=true skips busy nodes)
	@echo "=== Gracefully Unloading VAST NFS Modules ==="
	@NAMESPACE=$(NAMESPACE) KUBE_CMD=$(KUBE_CMD) PLATFORM=$(PLATFORM) ./scripts/graceful_unload.sh $(if $(filter true,$(FORCE)),--force,)

reinstall: create-namespace kustomize ## Reinstall when modules already loaded (skips in-tree removal)
	@$(call check_required_env,VASTNFS_VERSION KMM_IMG_REPO NAMESPACE)
	@echo "=== Safe Reinstall Mode ==="
	@echo "This mode is for scenarios where VAST NFS is already loaded on nodes."
	@echo "It applies the reinstall overlay in place and skips in-tree module removal."
	@echo ""
	@if NAMESPACE=$(NAMESPACE) KUBE_CMD=$(KUBE_CMD) PLATFORM=$(PLATFORM) ./scripts/check_vastnfs_loaded.sh 2>/dev/null; then \
		echo "VAST NFS is loaded - applying reinstall overlay without deleting the Module"; \
	else \
		echo "WARNING: VAST NFS not detected. Consider using 'make install' for fresh installation."; \
		echo "Proceeding with reinstall anyway..."; \
	fi
	@echo ""
	@echo "Applying Module with reinstall overlay..."
	@export VASTNFS_VERSION="$(VASTNFS_VERSION)"; \
	export KMM_IMG="$(KMM_IMG_REPO):$(KMM_IMG_TAG)"; \
	export NAMESPACE="$(NAMESPACE)"; \
	export KMM_PULL_SECRET="$(KMM_PULL_SECRET)"; \
	export BUILD_IMAGE="$(BUILD_IMAGE)"; \
	REINSTALL_DIR="k8s/overlays/$(PLATFORM)/reinstall"; \
	if [ ! -d "$$REINSTALL_DIR" ]; then REINSTALL_DIR="k8s/overlays/reinstall"; fi; \
	cd "$$REINSTALL_DIR" && \
	$(KUSTOMIZE) edit set namespace $(NAMESPACE) 2>/dev/null || true && \
	$(KUSTOMIZE) build . | envsubst '$$VASTNFS_VERSION $$KMM_IMG $$NAMESPACE $$KMM_PULL_SECRET $$BUILD_IMAGE' | $(KUBE_CMD) apply -f -
	@echo ""
	@echo "=== Reinstall Complete ==="
	@echo "Monitor with: $(KUBE_CMD) get pods -n $(NAMESPACE) -w"

######################
# NODE PREPARATION
######################
LABEL_SKIP ?= false

prepare-worker: ## Prepare a single worker node (NODE=<name> [LABEL_SKIP=true])
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make prepare-worker NODE=<node-name> [LABEL_SKIP=true]"; \
		echo "       make prepare-worker NODE=<node-name> MAX_ATTEMPTS=120 LABEL_SKIP=true"; \
		echo ""; \
		echo "Required environment variables:"; \
		echo "  VASTNFS_VERSION  - VAST NFS version (e.g., 4.5.5)"; \
		echo "  KMM_IMG_REPO     - Container registry"; \
		echo ""; \
		echo "Options:"; \
		echo "  LABEL_SKIP=true  - Ensure node is skipped by KMM after success"; \
		exit 1; \
	fi
	@$(call check_required_env,VASTNFS_VERSION KMM_IMG_REPO)
	@NAMESPACE=$(NAMESPACE) VASTNFS_VERSION=$(VASTNFS_VERSION) KMM_IMG_REPO=$(KMM_IMG_REPO) \
		VASTNFS_HELPER_IMAGE=$(HELPER_IMAGE) KUBE_CMD=$(KUBE_CMD) PLATFORM=$(PLATFORM) \
		./scripts/prepare_node_for_vastnfs.sh $(NODE) $(if $(MAX_ATTEMPTS),--max-attempts $(MAX_ATTEMPTS),) && \
	if [ "$(LABEL_SKIP)" = "true" ]; then \
		echo ""; \
		echo "[INFO] Ensuring node $(NODE) is skipped by KMM..."; \
		$(KUBE_CMD) label node $(NODE) vastnfs-kmm/enabled- 2>/dev/null || true; \
		if $(KUBE_CMD) get module vastnfs -n $(NAMESPACE) >/dev/null 2>&1; then \
			$(KUBE_CMD) patch module vastnfs -n $(NAMESPACE) --type=merge \
				-p '{"spec":{"selector":{"vastnfs-kmm/enabled":"true"}}}'; \
		fi; \
		echo "[SUCCESS] Node $(NODE) will be skipped by KMM"; \
	fi

prepare-workers: ## Prepare all worker nodes (rolling update) [LABEL_SKIP=true]
	@$(call check_required_env,VASTNFS_VERSION KMM_IMG_REPO)
	@NAMESPACE=$(NAMESPACE) VASTNFS_VERSION=$(VASTNFS_VERSION) KMM_IMG_REPO=$(KMM_IMG_REPO) \
		VASTNFS_HELPER_IMAGE=$(HELPER_IMAGE) LABEL_SKIP=$(LABEL_SKIP) KUBE_CMD=$(KUBE_CMD) PLATFORM=$(PLATFORM) \
		./scripts/prepare_all_workers.sh $(if $(MAX_ATTEMPTS),--max-attempts $(MAX_ATTEMPTS),)

install-systemd-unit: ## [vanilla] Install systemd unit to disable in-tree NFS on boot
	$(call require_platform,vanilla)
	@echo "Installing systemd unit to prevent in-tree NFS loading on boot..."
	@NAMESPACE=$(NAMESPACE) VASTNFS_HELPER_IMAGE=$(HELPER_IMAGE) KUBE_CMD=$(KUBE_CMD) \
		./scripts/install_systemd_unit.sh

######################
# NODE SELECTION HELPERS
######################
remove-node-from-kmm: ## Exclude a node from KMM module deployment (NODE=<node-name>)
ifndef NODE
	$(error NODE is required. Usage: make remove-node-from-kmm NODE=<node-name>)
endif
	@echo "Excluding node $(NODE) from KMM deployment..."
	@$(KUBE_CMD) label node $(NODE) vastnfs-kmm/enabled- 2>/dev/null || true
	@echo ""
	@echo "Ensuring Module selector requires enabled=true..."
	@if $(KUBE_CMD) get module vastnfs -n $(NAMESPACE) >/dev/null 2>&1; then \
		$(KUBE_CMD) patch module vastnfs -n $(NAMESPACE) --type=merge \
			-p '{"spec":{"selector":{"vastnfs-kmm/enabled":"true"}}}' && \
		echo "Module selector set to require vastnfs-kmm/enabled=true"; \
	else \
		echo "Note: Module not found - selector will be applied on next install"; \
	fi
	@echo ""
	@echo "Deleting worker pod for node $(NODE) (if exists)..."
	@$(KUBE_CMD) delete pod -n $(NAMESPACE) kmm-worker-$(NODE)-vastnfs --force --grace-period=0 2>/dev/null || true
	@echo ""
	@echo "[SUCCESS] Node $(NODE) excluded from KMM deployment"

add-node-to-kmm: ## Include a node in KMM module deployment (NODE=<node-name>)
ifndef NODE
	$(error NODE is required. Usage: make add-node-to-kmm NODE=<node-name>)
endif
	@echo "Including node $(NODE) in KMM deployment..."
	@$(KUBE_CMD) label node $(NODE) vastnfs-kmm/enabled=true --overwrite
	@echo ""
	@echo "Ensuring Module selector requires enabled=true..."
	@if $(KUBE_CMD) get module vastnfs -n $(NAMESPACE) >/dev/null 2>&1; then \
		$(KUBE_CMD) patch module vastnfs -n $(NAMESPACE) --type=merge \
			-p '{"spec":{"selector":{"vastnfs-kmm/enabled":"true"}}}' && \
		echo "Module selector updated"; \
	else \
		echo "Note: Module not found - selector will be applied on next install"; \
	fi
	@echo ""
	@echo "[SUCCESS] Node $(NODE) included in KMM deployment"

show-node-labels: ## Show vastnfs-kmm/enabled label status on all nodes
	@echo "Node KMM deployment status (vastnfs-kmm/enabled label):"
	@$(KUBE_CMD) get nodes -L vastnfs-kmm/enabled --no-headers | \
		awk '{if ($$6 == "true") print "  "$$1": INCLUDED (enabled=true)"; else print "  "$$1": EXCLUDED (no label)"}'

delete-module: ## Delete the Module and all worker pods (keeps built images)
	@echo "Deleting Module and worker pods..."
	@$(KUBE_CMD) patch module vastnfs -n $(NAMESPACE) -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
	@$(KUBE_CMD) delete module vastnfs -n $(NAMESPACE) --force --grace-period=0 2>/dev/null || true
	@$(KUBE_CMD) delete pods -n $(NAMESPACE) -l kmm.node.kubernetes.io/module.name=vastnfs --force --grace-period=0 2>/dev/null || true
	@echo "[SUCCESS] Module deleted. Worker pods stopped."

######################
# UNINSTALL
######################
cleanup-node-driver: ## Remove VAST NFS driver artifacts from all nodes
	@NAMESPACE=$(NAMESPACE) KUBE_CMD=$(KUBE_CMD) PLATFORM=$(PLATFORM) VASTNFS_HELPER_IMAGE=$(HELPER_IMAGE) \
		./scripts/cleanup_node_driver.sh

uninstall: graceful-unload ## Remove VAST NFS KMM resources and namespace from the cluster (FORCE=true skips busy nodes)
	@echo "Uninstalling VAST NFS KMM from namespace $(NAMESPACE)..."
	@echo ""
	@echo "[1/10] Removing VAST NFS driver artifacts from nodes..."
	@$(MAKE) cleanup-node-driver
	@echo ""
	@echo "[2/10] Cleaning up build pods..."
ifeq ($(PLATFORM),openshift)
	@$(KUBE_CMD) get builds -n $(NAMESPACE) -o name 2>/dev/null | xargs -r -I {} $(KUBE_CMD) patch {} -n $(NAMESPACE) -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	@$(KUBE_CMD) get builds -n $(NAMESPACE) -o name 2>/dev/null | xargs -r $(KUBE_CMD) delete --force --grace-period=0 -n $(NAMESPACE) 2>/dev/null || true
	@$(KUBE_CMD) delete pods -l openshift.io/build.name -n $(NAMESPACE) --force --grace-period=0 2>/dev/null || true
endif
	@$(KUBE_CMD) delete pods -l kmm.node.kubernetes.io/module.name=vastnfs -n $(NAMESPACE) --force --grace-period=0 2>/dev/null || true
	@echo ""
	@echo "[3/10] Deleting Module (force removing finalizers before/after delete)..."
	@$(KUBE_CMD) patch module vastnfs -n $(NAMESPACE) -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	@$(KUBE_CMD) delete module vastnfs -n $(NAMESPACE) --ignore-not-found --force --grace-period=0 --wait=false 2>/dev/null || true
	@for attempt in 1 2 3 4 5 6; do \
		if ! $(KUBE_CMD) get module vastnfs -n $(NAMESPACE) >/dev/null 2>&1; then break; fi; \
		$(KUBE_CMD) patch module vastnfs -n $(NAMESPACE) -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true; \
		$(KUBE_CMD) wait --for=delete module/vastnfs -n $(NAMESPACE) --timeout=5s >/dev/null 2>&1 && break; \
	done
	@echo ""
	@echo "[4/10] Deleting ModuleImagesConfig (force removing finalizers before/after delete)..."
	@$(KUBE_CMD) patch moduleimagesconfig vastnfs -n $(NAMESPACE) -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	@$(KUBE_CMD) delete moduleimagesconfig vastnfs -n $(NAMESPACE) --ignore-not-found --force --grace-period=0 --wait=false 2>/dev/null || true
	@for attempt in 1 2 3 4 5 6; do \
		if ! $(KUBE_CMD) get moduleimagesconfig vastnfs -n $(NAMESPACE) >/dev/null 2>&1; then break; fi; \
		$(KUBE_CMD) patch moduleimagesconfig vastnfs -n $(NAMESPACE) -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true; \
		$(KUBE_CMD) wait --for=delete moduleimagesconfig/vastnfs -n $(NAMESPACE) --timeout=5s >/dev/null 2>&1 && break; \
	done
	@echo ""
	@echo "[5/10] Cleaning up any remaining KMM-managed pods..."
	@$(KUBE_CMD) delete pods -n $(NAMESPACE) -l kmm.node.kubernetes.io/module.name=vastnfs --force --grace-period=0 2>/dev/null || true
	@$(KUBE_CMD) delete pods -n $(NAMESPACE) -l kmm.node.kubernetes.io/resource-type=BuildImage --force --grace-period=0 2>/dev/null || true
	@echo ""
	@echo "[6/10] Deleting ConfigMaps..."
	@$(KUBE_CMD) delete configmap vastnfs-kmm-build-dockerfile -n $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@$(KUBE_CMD) delete configmap -l app.kubernetes.io/name=vastnfs-kmm -n $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@echo ""
	@echo "[7/10] Deleting ServiceAccount and RBAC resources..."
	@$(KUBE_CMD) delete serviceaccount vastnfs-kmm-sa -n $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@$(KUBE_CMD) delete serviceaccount -l app.kubernetes.io/name=vastnfs-kmm -n $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@$(KUBE_CMD) delete clusterrole,clusterrolebinding -l app.kubernetes.io/name=vastnfs-kmm 2>/dev/null || true
ifeq ($(PLATFORM),openshift)
	@echo ""
	@echo "[7b/10] Cleaning up ImageStream..."
	@$(KUBE_CMD) delete imagestream vastnfs -n $(NAMESPACE) 2>/dev/null || true
endif
	@echo ""
	@echo "[8/10] Removing remaining namespaced resources..."
	@if $(KUBE_CMD) get namespace $(NAMESPACE) >/dev/null 2>&1; then \
		for resource in $$($(KUBE_CMD) api-resources --namespaced=true --verbs=list,delete -o name 2>/dev/null | sort -u); do \
			case "$$resource" in \
				events|events.events.k8s.io|pods/log|pods/status|*/status|*/scale|bindings|localsubjectaccessreviews.authorization.k8s.io) continue ;; \
			esac; \
			names=$$($(KUBE_CMD) get "$$resource" -n $(NAMESPACE) -o name 2>/dev/null || true); \
			if [ -n "$$names" ]; then \
				echo "$$names" | xargs -r $(KUBE_CMD) delete -n $(NAMESPACE) --ignore-not-found --wait=false 2>/dev/null || true; \
			fi; \
		done; \
	fi
	@echo ""
	@echo "[9/10] Removing node labels..."
	@for node in $$($(KUBE_CMD) get nodes -l vastnfs.vast.com/deploy=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do \
		echo "  Removing label from node: $$node"; \
		$(KUBE_CMD) label node "$$node" vastnfs.vast.com/deploy- 2>/dev/null || true; \
	done
	@echo ""
	@echo "[10/10] Deleting namespace $(NAMESPACE)..."
	@$(KUBE_CMD) delete namespace $(NAMESPACE) --ignore-not-found --wait=false 2>/dev/null || true
	@echo "Namespace deletion initiated (may take a moment to complete)."
	@echo ""
	@echo "=== Uninstall Complete ==="

######################
# SECURE BOOT TARGETS
######################
install-secure-boot: kustomize ## Install VAST NFS KMM with secure boot support
	@$(call check_required_env,$(REQ_INSTALL_ENV))
	@export VASTNFS_VERSION="$(VASTNFS_VERSION)"; \
	export KMM_IMG="$(KMM_IMG_REPO):$(SECURE_BOOT_KMM_IMG_TAG)"; \
	export NAMESPACE="$(NAMESPACE)"; \
	export KMM_PULL_SECRET="$(KMM_PULL_SECRET)"; \
	export BUILD_IMAGE="$(BUILD_IMAGE)"; \
	export KUSTOMIZE_DIR="$(SECURE_BOOT_KUSTOMIZE_DIR)"; \
	export NODE_SELECTOR="$(NODE_SELECTOR)"; \
	export PRIVATE_KEY_FILE="$(PRIVATE_KEY_FILE)"; \
	export PUBLIC_CERT_FILE="$(PUBLIC_CERT_FILE)"; \
	export MOK_PASSWORD="$(MOK_PASSWORD)"; \
	export MOK_PASSWORD_FILE="$(MOK_PASSWORD_FILE)"; \
	export MOK_PROMPT_TIMEOUT="$(MOK_PROMPT_TIMEOUT)"; \
	export KEYS_DIR="$(KEYS_DIR)"; \
	export KEY_NAME="$(KEY_NAME)"; \
	export HELPER_IMAGE="$(HELPER_IMAGE)"; \
	export KUSTOMIZE="$(KUSTOMIZE)"; \
	export PLATFORM="$(PLATFORM)"; \
	export KUBE_CMD="$(KUBE_CMD)"; \
	./scripts/install_with_secure_boot.sh --follow-logs

generate-secure-boot-keys: ## Generate secure boot keys for kernel module signing
	@./scripts/generate_secure_boot_keys.sh

verify-secure-boot: ## Verify secure boot deployment (platform-aware)
	@echo "=== Verifying Secure Boot Deployment ==="
	@echo "1. Checking module status..."
	@$(KUBE_CMD) get module vastnfs -n $(NAMESPACE) 2>/dev/null || echo "Module not found"
	@echo ""
	@echo "2. Checking for signed modules on nodes..."
ifeq ($(PLATFORM),openshift)
	@nodes="$$($(KUBE_CMD) get nodes -l "$(NODE_SELECTOR)" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"; \
	if [ -z "$$nodes" ]; then nodes="$$($(KUBE_CMD) get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"; fi; \
	if [ -z "$$nodes" ]; then nodes="$$($(KUBE_CMD) get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"; fi; \
	for node in $$nodes; do \
		echo "--- Checking $$node ---"; \
		echo "VAST NFS Status:"; \
		$(KUBE_CMD) debug node/$$node -- chroot /host cat /sys/module/sunrpc/parameters/nfs_bundle_version 2>/dev/null && echo " (VAST NFS ACTIVE)" || echo "VAST NFS not active"; \
		echo "Module signature:"; \
		$(KUBE_CMD) debug node/$$node -- chroot /host modinfo sunrpc | grep signature 2>/dev/null || echo "No signature found"; \
		echo "Secure boot status:"; \
		$(KUBE_CMD) debug node/$$node -- chroot /host mokutil --sb-state 2>/dev/null || echo "mokutil not available"; \
		echo ""; \
	done
else
	@nodes="$$($(KUBE_CMD) get nodes -l "$(NODE_SELECTOR)" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"; \
	if [ -z "$$nodes" ]; then nodes="$$($(KUBE_CMD) get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"; fi; \
	if [ -z "$$nodes" ]; then nodes="$$($(KUBE_CMD) get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"; fi; \
	for node in $$nodes; do \
		echo "--- Checking $$node ---"; \
		echo "VAST NFS Status:"; \
		$(KUBE_CMD) run "sb-ver-$$node-$$$$" --rm -i --restart=Never --image=busybox \
			--overrides='{"spec":{"nodeName":"'"$$node"'","hostPID":true,"containers":[{"name":"c","image":"busybox","command":["cat","/host-sys/module/sunrpc/parameters/nfs_bundle_version"],"volumeMounts":[{"name":"sys","mountPath":"/host-sys","readOnly":true}]}],"volumes":[{"name":"sys","hostPath":{"path":"/sys","type":"Directory"}}],"tolerations":[{"operator":"Exists"}]}}' 2>/dev/null && echo " (VAST NFS ACTIVE)" || echo "VAST NFS not active"; \
		echo "Module signature:"; \
		$(KUBE_CMD) run "sb-sig-$$node-$$$$" --rm -i --restart=Never --image=busybox \
			--overrides='{"spec":{"nodeName":"'"$$node"'","hostPID":true,"containers":[{"name":"c","image":"busybox","command":["nsenter","-t","1","-m","-u","-i","-n","--","modinfo","sunrpc"],"securityContext":{"privileged":true}}],"tolerations":[{"operator":"Exists"}]}}' 2>/dev/null | grep signature || echo "No signature found"; \
		echo "Secure boot status:"; \
		$(KUBE_CMD) run "sb-state-$$node-$$$$" --rm -i --restart=Never --image=busybox \
			--overrides='{"spec":{"nodeName":"'"$$node"'","hostPID":true,"containers":[{"name":"c","image":"busybox","command":["nsenter","-t","1","-m","-u","-i","-n","--","mokutil","--sb-state"],"securityContext":{"privileged":true}}],"tolerations":[{"operator":"Exists"}]}}' 2>/dev/null || echo "mokutil not available"; \
		echo ""; \
	done
endif

######################
# VERIFICATION
######################
verify: ## Verify deployment (VERBOSE=true for detailed, NODE=<name> for single node)
	@echo "=== Verifying VAST NFS Deployment ==="
	@echo "Platform: $(PLATFORM) (KUBE_CMD=$(KUBE_CMD))"
	@echo ""
	@VERBOSE=$(VERBOSE) KUBE_CMD=$(KUBE_CMD) PLATFORM=$(PLATFORM) \
		./scripts/verify_deployment.sh --namespace $(NAMESPACE) $(if $(NODE),--node $(NODE),)

######################
# UTILITY TARGETS
######################
clean-debug-pods: ## Clean up leftover kubectl/oc debug pods
	@echo "Cleaning up debug pods created by vastnfs-kmm scripts..."
	@echo "Looking for node-debugger pods..."
	@$(KUBE_CMD) get pods -A --no-headers 2>/dev/null | grep "node-debugger" | while read ns pod rest; do \
		echo "  Deleting $$ns/$$pod"; \
		$(KUBE_CMD) delete pod "$$pod" -n "$$ns" --ignore-not-found --force --grace-period=0 2>/dev/null || true; \
	done || true
	@echo "Looking for OpenShift node debug pods..."
	@$(KUBE_CMD) get pods -A --no-headers 2>/dev/null | grep -E "^[^[:space:]]+[[:space:]]+[^[:space:]]+-debug-[[:alnum:]]+" | while read ns pod rest; do \
		echo "  Deleting $$ns/$$pod"; \
		$(KUBE_CMD) delete pod "$$pod" -n "$$ns" --ignore-not-found --force --grace-period=0 2>/dev/null || true; \
	done || true
	@echo "Looking for vastnfs helper pods..."
	@$(KUBE_CMD) get pods -A --no-headers 2>/dev/null | grep -E "(vastnfs-|chk-vastnfs-|sb-|graceful-unload-|get-kver-|verify-|final-verify-|status-)" | while read ns pod rest; do \
		echo "  Deleting $$ns/$$pod"; \
		$(KUBE_CMD) delete pod "$$pod" -n "$$ns" --ignore-not-found --force --grace-period=0 2>/dev/null || true; \
	done || true
	@echo "Debug pod cleanup complete"

show-config: ## Show current configuration
	@echo "=== Current Configuration ==="
	@echo ""
	@echo "Platform Selection:"
	@echo "  PLATFORM:        $(PLATFORM)"
	@echo "  KUBE_CMD:        $(KUBE_CMD)"
	@echo ""
	@echo "Deployment:"
	@echo "  VASTNFS_VERSION: $(VASTNFS_VERSION)"
	@echo "  NAMESPACE:       $(NAMESPACE)"
	@echo "  KUSTOMIZE_DIR:   $(KUSTOMIZE_DIR)"
	@echo "  KMM_IMG_REPO:    $(KMM_IMG_REPO)"
	@echo "  KMM_IMG_TAG:     $(KMM_IMG_TAG)"
	@echo "  KMM_PULL_SECRET: $(KMM_PULL_SECRET)"
	@echo "  NODE_SELECTOR:   $(NODE_SELECTOR)"
ifeq ($(PLATFORM),vanilla)
	@echo ""
	@echo "Vanilla-specific:"
	@echo "  BUILD_IMAGE:     $(BUILD_IMAGE)"
	@echo "  HELPER_IMAGE:    $(HELPER_IMAGE)"
	@echo ""
	@echo "Build images per kernel type (automatic):"
	@echo "  Ubuntu/Debian kernels  -> ubuntu:22.04"
	@echo "  RHEL 9/Rocky 9 kernels -> rockylinux:9"
	@echo "  RHEL 8/Rocky 8 kernels -> rockylinux:8"
	@echo "  Fedora kernels         -> fedora:latest"
	@echo "  SUSE kernels           -> opensuse/leap"
endif

######################
# MIGRATION FROM LEGACY OCP INSTALLS
######################
migrate-from-legacy: ## Migrate a legacy OpenShift install to the unified manifest layout
	@APPLY=$(APPLY) ALLOW_RELOAD=$(ALLOW_RELOAD) NAMESPACE=$(NAMESPACE) \
		KUBE_CMD=$(KUBE_CMD) PLATFORM=$(PLATFORM) VASTNFS_VERSION=$(VASTNFS_VERSION) \
		./scripts/migrate_from_legacy.sh

endif

######################
# HELP
######################
help: ## Show available targets
	@if [ -z "$(HELP_TOPIC)" ]; then \
		echo "VAST NFS KMM Operator (platform-aware)"; \
		echo ""; \
		echo "Current platform: $(PLATFORM)  (KUBE_CMD=$(KUBE_CMD))"; \
		echo "Override with:    make <target> PLATFORM=openshift|vanilla"; \
		echo ""; \
		echo "Usage:"; \
		echo "  make help              Show available targets"; \
		echo "  make help <target>     Show detailed target parameters"; \
		echo ""; \
		echo "Available targets:"; \
		awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST); \
	else \
		p() { printf "  %-30s %s\n" "$$1" "$$2"; }; \
		common_params() { \
			p "PLATFORM" "Target platform: openshift or vanilla. Defaults to scripts/detect_platform.sh."; \
			p "KUBE_CMD" "Kubernetes CLI. Defaults to oc/kubectl based on PLATFORM."; \
			p "NAMESPACE" "Namespace for VAST NFS KMM resources. Default: vastnfs-kmm."; \
			p "VASTNFS_VERSION" "VAST NFS version to deploy or build. Required on vanilla; OpenShift defaults to 4.0.35."; \
			p "KMM_IMG_REPO" "Kernel module image repository. Required on vanilla; OpenShift defaults to the internal registry."; \
			p "KMM_IMG_TAG" "Kernel module image tag template. Default: kernel version plus VASTNFS_VERSION."; \
			p "KMM_PULL_SECRET" "Optional image pull secret name; uses the with-pull-secret overlay when set."; \
			p "KUSTOMIZE_DIR" "Overlay to render for normal installs. Defaults to the platform base overlay."; \
			p "NODE_SELECTOR" "Optional key=value selector for limiting Module deployment and checks."; \
		}; \
		echo "VAST NFS KMM Operator help: $(HELP_TOPIC)"; \
		echo ""; \
		case "$(HELP_TOPIC)" in \
			help) \
				echo "Usage: make help [target]"; \
				echo ""; \
				echo "Shows the target list or detailed help for one target."; \
				echo ""; \
				echo "Parameters:"; \
				p "PLATFORM" "Affects auto-detected defaults displayed in help."; \
				p "KUBE_CMD" "Affects auto-detected CLI displayed in help."; \
				;; \
			show-config) \
				echo "Usage: make show-config [parameters]"; \
				echo ""; \
				echo "Prints the resolved platform, Kubernetes CLI, image, namespace, overlay, and node-selection configuration."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "BUILD_IMAGE" "Vanilla build base image selected by scripts/detect_build_image.sh when unset."; \
				p "HELPER_IMAGE" "Helper image for vanilla/nsenter pods. Default: alpine:latest."; \
				;; \
			kustomize|install-kustomize) \
				echo "Usage: make $(HELP_TOPIC) [parameters]"; \
				echo ""; \
				echo "Downloads the pinned kustomize binary into the local bin directory if it is missing."; \
				echo ""; \
				echo "Parameters:"; \
				p "LOCALBIN" "Directory for local tools. Default: ./bin."; \
				p "KUSTOMIZE" "Path to the kustomize binary. Default: \$$(LOCALBIN)/kustomize."; \
				p "KUSTOMIZE_VERSION" "Kustomize release to download. Default: v5.4.3."; \
				;; \
			create-namespace) \
				echo "Usage: make create-namespace [parameters]"; \
				echo ""; \
				echo "Creates the target namespace when it does not already exist."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				;; \
			install) \
				echo "Usage: make install VASTNFS_VERSION=<version> [parameters]"; \
				echo ""; \
				echo "Installs or upgrades VAST NFS KMM. If VAST NFS is already loaded, it performs a graceful unload first."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "BUILD_IMAGE" "Vanilla build base image. Auto-detected when unset."; \
				p "ALLOW_UNSIGNED_ON_SECURE_BOOT" "Set true to bypass the guard that blocks unsigned installs on Secure Boot nodes."; \
				;; \
			build-installer) \
				echo "Usage: make build-installer VASTNFS_VERSION=<version> [parameters]"; \
				echo ""; \
				echo "Renders the selected kustomize overlay into dist/install.yaml without applying it."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				;; \
			build-only) \
				echo "Usage: make build-only VASTNFS_VERSION=<version> KMM_IMG_REPO=<repo> [parameters]"; \
				echo ""; \
				echo "Builds kernel module images into the configured registry without deploying worker pods."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "FORCE" "Set true to clear existing images/caches before rebuilding."; \
				p "HELPER_IMAGE" "Image used for helper pods. Default: alpine:latest."; \
				;; \
			verify) \
				echo "Usage: make verify [VERBOSE=true] [NODE=<node>] [parameters]"; \
				echo ""; \
				echo "Checks deployment health across the cluster or one selected node."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "VERBOSE" "Set true for detailed node and pod diagnostics."; \
				p "NODE" "Limit verification to one node."; \
				;; \
			graceful-unload) \
				echo "Usage: make graceful-unload [FORCE=true] [parameters]"; \
				echo ""; \
				echo "Cordons target nodes, unmounts NFS clients, stops RPC services, and unloads VAST NFS modules."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "FORCE" "Set true to pass --force and skip nodes where modules are still busy."; \
				;; \
			reinstall) \
				echo "Usage: make reinstall VASTNFS_VERSION=<version> KMM_IMG_REPO=<repo> [parameters]"; \
				echo ""; \
				echo "Re-applies the Module when VAST NFS is already loaded, using the reinstall overlay to avoid in-tree removal."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "BUILD_IMAGE" "Vanilla build base image. Auto-detected when unset."; \
				;; \
			prepare-worker) \
				echo "Usage: make prepare-worker NODE=<node> VASTNFS_VERSION=<version> KMM_IMG_REPO=<repo> [parameters]"; \
				echo ""; \
				echo "Prepares one worker node by draining it, unloading in-tree NFS, and allowing KMM to load VAST NFS."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "NODE" "Worker node to prepare. Required."; \
				p "LABEL_SKIP" "Set true to remove the KMM enabled label after success so the node is skipped later."; \
				p "MAX_ATTEMPTS" "Maximum readiness/build polling attempts passed to the preparation script."; \
				p "HELPER_IMAGE" "Image used for helper/nsenter pods. Default: alpine:latest."; \
				;; \
			prepare-workers) \
				echo "Usage: make prepare-workers VASTNFS_VERSION=<version> KMM_IMG_REPO=<repo> [parameters]"; \
				echo ""; \
				echo "Runs worker preparation as a rolling update across all worker nodes."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "LABEL_SKIP" "Set true to remove KMM enabled labels after each successful node preparation."; \
				p "MAX_ATTEMPTS" "Maximum readiness/build polling attempts passed to the preparation script."; \
				p "HELPER_IMAGE" "Image used for helper/nsenter pods. Default: alpine:latest."; \
				;; \
			install-systemd-unit) \
				echo "Usage: make install-systemd-unit PLATFORM=vanilla [parameters]"; \
				echo ""; \
				echo "Installs a systemd unit on nodes to prevent in-tree NFS modules from loading at boot. Vanilla only."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "HELPER_IMAGE" "Image used for helper/nsenter pods. Default: alpine:latest."; \
				;; \
			add-node-to-kmm|remove-node-from-kmm) \
				echo "Usage: make $(HELP_TOPIC) NODE=<node> [parameters]"; \
				echo ""; \
				echo "Adds or removes the vastnfs-kmm/enabled label and keeps the Module selector aligned."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "NODE" "Node to include in or exclude from KMM deployment. Required."; \
				;; \
			show-node-labels) \
				echo "Usage: make show-node-labels [parameters]"; \
				echo ""; \
				echo "Shows the vastnfs-kmm/enabled label status for every node."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				;; \
			delete-module) \
				echo "Usage: make delete-module [parameters]"; \
				echo ""; \
				echo "Deletes the KMM Module and worker pods while keeping built images and other resources."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				;; \
			cleanup-node-driver) \
				echo "Usage: make cleanup-node-driver [parameters]"; \
				echo ""; \
				echo "Removes VAST NFS driver artifacts from cluster nodes."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "HELPER_IMAGE" "Image used for helper/nsenter pods. Default: alpine:latest."; \
				;; \
			uninstall) \
				echo "Usage: make uninstall [FORCE=true] [parameters]"; \
				echo ""; \
				echo "Removes VAST NFS KMM resources and deletes the namespace."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "FORCE" "Set true to skip nodes where modules are still busy during graceful unload."; \
				p "HELPER_IMAGE" "Image used while cleaning node driver artifacts. Default: alpine:latest."; \
				;; \
			install-secure-boot) \
				echo "Usage: make install-secure-boot VASTNFS_VERSION=<version> [parameters]"; \
				echo ""; \
				echo "Installs signed VAST NFS modules, creating or reusing signing keys and staging MOK enrollment when needed."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "SECURE_BOOT_KUSTOMIZE_DIR" "Secure Boot overlay to render. Default: k8s/overlays/\$$(PLATFORM)/secure-boot."; \
				p "SECURE_BOOT_KMM_IMG_TAG" "Image tag for signed module images. Default: \$$(KMM_IMG_TAG)-secureboot."; \
				p "PRIVATE_KEY_FILE" "Existing signing private key. Must be paired with PUBLIC_CERT_FILE."; \
				p "PUBLIC_CERT_FILE" "Existing signing public DER certificate. Must be paired with PRIVATE_KEY_FILE."; \
				p "KEYS_DIR" "Directory for generated/reused signing keys."; \
				p "KEY_NAME" "Generated/reused signing key prefix."; \
				p "MOK_PASSWORD_FILE" "File containing the one-time MOK enrollment password."; \
				p "MOK_PASSWORD" "One-time MOK enrollment password, mainly for lab use."; \
				p "MOK_PROMPT_TIMEOUT" "MokManager prompt timeout in seconds. Default: 60."; \
				p "SIGNING_KEY_SECRET" "Secret name for the signing private key."; \
				p "SIGNING_CERT_SECRET" "Secret name for the signing public certificate."; \
				p "IMAGE_REPO_SECRET" "Secret name referenced by the secure-boot overlay for registry auth."; \
				p "BUILD_IMAGE" "Vanilla build base image. Auto-detected when unset."; \
				p "HELPER_IMAGE" "Image used for helper/nsenter pods. Default: alpine:latest."; \
				;; \
			generate-secure-boot-keys) \
				echo "Usage: make generate-secure-boot-keys [parameters]"; \
				echo ""; \
				echo "Generates reusable Secure Boot signing keys."; \
				echo ""; \
				echo "Parameters:"; \
				p "KEYS_DIR" "Keys output directory."; \
				p "KEY_NAME" "Signing key file prefix."; \
				p "CERT_VALIDITY_DAYS" "Certificate validity period in days."; \
				;; \
			verify-secure-boot) \
				echo "Usage: make verify-secure-boot [parameters]"; \
				echo ""; \
				echo "Checks Module status, module signatures, and Secure Boot state on target nodes."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				;; \
			clean-debug-pods) \
				echo "Usage: make clean-debug-pods [parameters]"; \
				echo ""; \
				echo "Deletes leftover debug/helper pods created by the install, verify, unload, and Secure Boot scripts."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				;; \
			migrate-from-legacy) \
				echo "Usage: make migrate-from-legacy [APPLY=true] [ALLOW_RELOAD=true] [parameters]"; \
				echo ""; \
				echo "Migrates legacy OpenShift resources to the unified manifest layout. Defaults to dry-run."; \
				echo ""; \
				echo "Parameters:"; \
				common_params; \
				p "APPLY" "Set true to perform the migration. Default: false dry-run."; \
				p "ALLOW_RELOAD" "Set true to allow actions that may reload VAST NFS during migration."; \
				;; \
			*) \
				echo "Unknown help topic: $(HELP_TOPIC)"; \
				echo "Run 'make help' to list available targets."; \
				;; \
		esac; \
	fi
