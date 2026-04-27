#!/bin/bash

# Common functions and utilities for VAST NFS KMM scripts.
#
# This file should be sourced by other scripts, not executed directly.
#
# It is platform-aware: pass PLATFORM=openshift|vanilla (or let it be
# auto-detected) and the helpers route to `oc` or `kubectl` as appropriate.
# All k8s operations use ${KUBE_CMD} so callers can override with any
# compatible CLI.

# Exit if sourced incorrectly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script should be sourced, not executed directly"
    echo "Usage: source scripts/common.sh"
    exit 1
fi

# ---- Colors ----------------------------------------------------------------
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

# ---- Defaults --------------------------------------------------------------
export DEFAULT_NAMESPACE="vastnfs-kmm"
export DEFAULT_VASTNFS_VERSION="4.0.35"
export DEFAULT_KEYS_DIR="keys"
export DEFAULT_KEY_NAME="vastnfs_signing_key"
export DEFAULT_CERT_VALIDITY_DAYS="36500"

# Signing secrets defaults
export DEFAULT_SIGNING_KEY_SECRET="vastnfs-signing-key"
export DEFAULT_SIGNING_CERT_SECRET="vastnfs-signing-cert"
export DEFAULT_IMAGE_REPO_SECRET="vastnfs-registry-secret"

# Image configuration default.
# The OpenShift internal registry is the default target for the OpenShift
# platform. Vanilla users must supply KMM_IMG_REPO explicitly.
export DEFAULT_KMM_IMG_REPO="image-registry.openshift-image-registry.svc:5000/vastnfs-kmm/vastnfs"

# ---- Platform detection + kube CLI selection -------------------------------
_common_detect_platform() {
    if [[ -n "${PLATFORM:-}" ]]; then
        echo "${PLATFORM}"
        return
    fi
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "${here}/detect_platform.sh" ]]; then
        "${here}/detect_platform.sh"
    else
        echo "vanilla"
    fi
}

export PLATFORM="${PLATFORM:-$(_common_detect_platform)}"

# KUBE_CMD: the CLI used for all cluster operations in these scripts.
# - openshift default: `oc` (preserves legacy behavior for OpenShift users)
# - vanilla default:   `kubectl`
# Users may override with KUBE_CMD=kubectl even on OpenShift to avoid `oc`.
if [[ -z "${KUBE_CMD:-}" ]]; then
    if [[ "${PLATFORM}" == "openshift" ]] && command -v oc >/dev/null 2>&1; then
        KUBE_CMD="oc"
    elif command -v kubectl >/dev/null 2>&1; then
        KUBE_CMD="kubectl"
    elif command -v oc >/dev/null 2>&1; then
        KUBE_CMD="oc"
    else
        KUBE_CMD="kubectl"
    fi
fi
export KUBE_CMD

# ---- Print helpers ---------------------------------------------------------
print_header() {
    local title="$1"
    echo -e "${BLUE}"
    echo "================================================================="
    echo "  $title"
    echo "================================================================="
    echo -e "${NC}"
}

print_step()    { echo -e "${GREEN}[STEP]${NC} $1"; }
print_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# ---- Misc utilities --------------------------------------------------------
check_command() {
    local cmd="$1"
    local install_msg="$2"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "$cmd not found"
        if [[ -n "$install_msg" ]]; then
            echo "$install_msg"
        fi
        return 1
    fi
    return 0
}

# ---- Cluster connection ----------------------------------------------------
# Platform-aware cluster check. Preserves legacy name `check_openshift_login`
# as an alias for existing callers.
check_cluster_connection() {
    print_step "Checking Kubernetes cluster connection..."

    if [[ "${PLATFORM}" == "openshift" ]] && [[ "${KUBE_CMD}" == "oc" ]]; then
        if ! oc whoami &>/dev/null; then
            print_error "Not logged in to OpenShift cluster"
            echo "Please run: oc login --server=https://your-cluster-api:6443"
            return 1
        fi
        local user server
        user=$(oc whoami)
        server=$(oc whoami --show-server)
        print_info "Connected as: $user"
        print_info "Cluster: $server"
        return 0
    fi

    if ! "${KUBE_CMD}" cluster-info >/dev/null 2>&1; then
        print_error "Not connected to Kubernetes cluster"
        echo "Please ensure your kubeconfig is properly configured"
        return 1
    fi

    local context
    context=$("${KUBE_CMD}" config current-context 2>/dev/null || echo "unknown")
    print_info "Connected to context: $context"
    return 0
}

# Backward-compatibility alias: existing scripts call check_openshift_login.
check_openshift_login() {
    check_cluster_connection "$@"
}

check_prerequisites() {
    print_step "Checking prerequisites..."

    local failed=0

    # Check the CLI we will actually use.
    if ! check_command "${KUBE_CMD}" "Please install '${KUBE_CMD}'"; then
        failed=1
    fi

    # Check kustomize - use KUSTOMIZE env var if set, otherwise check PATH
    if [[ -n "$KUSTOMIZE" ]]; then
        if [[ ! -x "$KUSTOMIZE" ]]; then
            print_error "kustomize not found at: $KUSTOMIZE"
            failed=1
        fi
    else
        if ! check_command "kustomize" "Please install kustomize or run: make kustomize"; then
            failed=1
        fi
    fi

    # Check envsubst
    if ! check_command "envsubst" "Please install gettext package:
  - RHEL/CentOS: sudo dnf install gettext
  - Ubuntu/Debian: sudo apt install gettext-base
  - macOS: brew install gettext"; then
        failed=1
    fi

    if [[ $failed -eq 1 ]]; then
        return 1
    fi

    print_info "All prerequisites met (platform=${PLATFORM}, kube=${KUBE_CMD})"
    return 0
}

check_openssl() {
    print_step "Checking OpenSSL..."

    if ! check_command "openssl" "Please install OpenSSL:
  - RHEL/CentOS: sudo dnf install openssl
  - Ubuntu/Debian: sudo apt install openssl
  - macOS: brew install openssl"; then
        return 1
    fi

    print_info "OpenSSL available: $(openssl version)"
    return 0
}

# ---- k8s operations --------------------------------------------------------
create_namespace_if_not_exists() {
    local namespace="$1"

    if ! "${KUBE_CMD}" get namespace "$namespace" >/dev/null 2>&1; then
        print_step "Creating namespace: $namespace"
        "${KUBE_CMD}" create namespace "$namespace"
        print_info "Created namespace: $namespace"
    else
        print_info "Namespace $namespace already exists"
    fi
}

check_secret_exists() {
    local secret_name="$1"
    local namespace="$2"

    "${KUBE_CMD}" get secret "$secret_name" -n "$namespace" >/dev/null 2>&1
}

wait_for_openshift_service_account_pull_secret() {
    local namespace="$1"
    local service_account="$2"
    local timeout="${3:-60}"
    local elapsed=0
    local pull_secret=""

    if [[ "${PLATFORM}" != "openshift" ]]; then
        return 0
    fi

    print_step "Waiting for OpenShift service account pull secret..."

    while [ "$elapsed" -lt "$timeout" ]; do
        pull_secret=$("${KUBE_CMD}" get serviceaccount "$service_account" -n "$namespace" \
            -o jsonpath='{.imagePullSecrets[0].name}' 2>/dev/null || true)

        if [ -n "$pull_secret" ] && "${KUBE_CMD}" get secret "$pull_secret" -n "$namespace" >/dev/null 2>&1; then
            print_success "ServiceAccount $service_account has pull secret $pull_secret"
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    print_warning "Timed out waiting for pull secret on ServiceAccount $service_account"
    return 1
}

refresh_openshift_kmm_worker_pods() {
    local namespace="$1"
    local service_account="$2"
    local module_name="${3:-vastnfs}"

    if [[ "${PLATFORM}" != "openshift" ]]; then
        return 0
    fi

    if ! wait_for_openshift_service_account_pull_secret "$namespace" "$service_account"; then
        return 0
    fi

    print_step "Refreshing KMM worker pods to pick up current pull secret..."
    "${KUBE_CMD}" delete pods -n "$namespace" \
        -l "app.kubernetes.io/component=worker,kmm.node.kubernetes.io/module.name=$module_name" \
        --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}

create_secret_from_file() {
    local secret_name="$1"
    local namespace="$2"
    local key_name="$3"
    local file_path="$4"
    local overwrite="${5:-false}"

    if check_secret_exists "$secret_name" "$namespace"; then
        if [[ "$overwrite" == "true" ]]; then
            print_warning "Secret $secret_name already exists, overwriting..."
            "${KUBE_CMD}" delete secret "$secret_name" -n "$namespace"
        else
            print_warning "Secret $secret_name already exists, skipping creation"
            return 0
        fi
    fi

    "${KUBE_CMD}" create secret generic "$secret_name" \
        --from-file="$key_name=$file_path" \
        -n "$namespace"

    print_info "Created secret: $secret_name"
}

verify_secret_content() {
    local secret_name="$1"
    local namespace="$2"
    local key_name="$3"
    local validation_cmd="$4"

    print_step "Verifying secret: $secret_name"

    if "${KUBE_CMD}" get secret "$secret_name" -n "$namespace" -o yaml | \
       awk "/$key_name:/{print \$2; exit}" | base64 -d | \
       eval "$validation_cmd" >/dev/null 2>&1; then
        print_info "Secret $secret_name is valid"
        return 0
    else
        print_error "Secret $secret_name is invalid"
        return 1
    fi
}

# ---- File utilities --------------------------------------------------------
ensure_directory() {
    local dir="$1"
    local permissions="${2:-755}"

    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        chmod "$permissions" "$dir"
        print_info "Created directory: $dir"
    fi
}

check_file_exists() {
    local file="$1"
    local description="${2:-file}"

    if [[ ! -f "$file" ]]; then
        print_error "$description not found: $file"
        return 1
    fi
    return 0
}

set_file_permissions() {
    local file="$1"
    local permissions="$2"

    chmod "$permissions" "$file"
    print_info "Set permissions $permissions on: $file"
}

# ---- Config / validation ---------------------------------------------------
validate_required_vars() {
    local vars=("$@")
    local missing=()

    for var in "${vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing required environment variables:"
        for var in "${missing[@]}"; do
            echo "  - $var"
        done
        return 1
    fi

    return 0
}

show_configuration() {
    local title="$1"
    shift
    local vars=("$@")

    print_step "$title"
    for var in "${vars[@]}"; do
        echo "  $var: ${!var}"
    done
    echo ""
}

show_common_help_footer() {
    echo ""
    echo "Common Environment Variables:"
    echo "  PLATFORM                      openshift | vanilla (default: auto-detected)"
    echo "  KUBE_CMD                      kubectl | oc (default: platform-based)"
    echo "  NAMESPACE                     Kubernetes namespace (default: $DEFAULT_NAMESPACE)"
    echo "  VASTNFS_VERSION               VAST NFS version (default: $DEFAULT_VASTNFS_VERSION)"
    echo ""
    echo "For more help, see the documentation in the project repository."
}

# ---- Cleanup helpers -------------------------------------------------------
cleanup_temp_files() {
    local files=("$@")

    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            print_info "Cleaned up temporary file: $file"
        fi
    done
}

cleanup_temp_dirs() {
    local dirs=("$@")

    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            print_info "Cleaned up temporary directory: $dir"
        fi
    done
}

setup_cleanup_trap() {
    local cleanup_function="$1"
    trap "$cleanup_function" EXIT INT TERM
}

# ---- Version checks --------------------------------------------------------
check_kubernetes_version() {
    local min_version="${1:-1.25}"

    if ! "${KUBE_CMD}" version --client=false >/dev/null 2>&1; then
        print_warning "Could not determine Kubernetes version"
        return 0
    fi

    print_info "Kubernetes cluster accessible"
    return 0
}

# Legacy alias
check_openshift_version() {
    local min_version="${1:-4.12}"

    if [[ "${PLATFORM}" == "openshift" ]] && [[ "${KUBE_CMD}" == "oc" ]]; then
        if ! oc version --client=false >/dev/null 2>&1; then
            print_warning "Could not determine OpenShift version"
            return 0
        fi
        print_info "OpenShift cluster accessible"
        return 0
    fi

    check_kubernetes_version "$min_version"
}

# ---- Module / deployment helpers ------------------------------------------
get_module_status() {
    local module_name="$1"
    local namespace="$2"

    "${KUBE_CMD}" get module "$module_name" -n "$namespace" \
        -o jsonpath='{.status.moduleLoader}' 2>/dev/null
}

wait_for_module_ready() {
    local module_name="$1"
    local namespace="$2"
    local timeout="${3:-300}"

    print_step "Waiting for module $module_name to be ready (timeout: ${timeout}s)..."

    local count=0
    while [[ $count -lt $timeout ]]; do
        local status
        status=$(get_module_status "$module_name" "$namespace")
        if [[ -n "$status" ]]; then
            local available desired
            available=$(echo "$status" | jq -r '.availableNumber // 0' 2>/dev/null)
            desired=$(echo "$status" | jq -r '.desiredNumber // 0' 2>/dev/null)

            if [[ "$available" == "$desired" ]] && [[ "$available" -gt 0 ]]; then
                print_success "Module $module_name is ready"
                return 0
            fi
        fi

        sleep 5
        count=$((count + 5))
    done

    print_error "Module $module_name did not become ready within ${timeout}s"
    return 1
}

# ---- Exports ---------------------------------------------------------------
export -f print_header print_step print_info print_warning print_error print_success
export -f check_command check_cluster_connection check_openshift_login check_prerequisites check_openssl
export -f create_namespace_if_not_exists check_secret_exists create_secret_from_file verify_secret_content
export -f ensure_directory check_file_exists set_file_permissions
export -f validate_required_vars show_configuration show_common_help_footer
export -f cleanup_temp_files cleanup_temp_dirs setup_cleanup_trap
export -f check_kubernetes_version check_openshift_version get_module_status wait_for_module_ready

# Indicate that common.sh has been loaded
export COMMON_SH_LOADED=1
