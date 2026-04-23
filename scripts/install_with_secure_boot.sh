#!/usr/bin/env bash

# VAST NFS KMM Deployment with Secure Boot Support.
#
# Sets up and deploys VAST NFS with kernel-module signing, using the
# secure-boot overlay for the current platform (openshift | vanilla).
#
# Platform-aware:
#   - Uses ${KUBE_CMD} from common.sh (default: oc on openshift, kubectl
#     on vanilla; override with KUBE_CMD=...).
#   - The secure-boot overlay lives at
#     `k8s/overlays/${PLATFORM}/secure-boot` by default. Legacy layout
#     (`k8s/overlays/secure-boot` as an alias) also works.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---- Configuration ---------------------------------------------------------
NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
VASTNFS_VERSION="${VASTNFS_VERSION:-}"
# Default to the platform's secure-boot overlay. Users can still pass the
# legacy `k8s/overlays/secure-boot` path via KUSTOMIZE_DIR; both work.
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-k8s/overlays/${PLATFORM}/secure-boot}"
FOLLOW_LOGS=false

# Secure Boot specific configuration
SIGNING_KEY_SECRET="${SIGNING_KEY_SECRET:-$DEFAULT_SIGNING_KEY_SECRET}"
SIGNING_CERT_SECRET="${SIGNING_CERT_SECRET:-$DEFAULT_SIGNING_CERT_SECRET}"
IMAGE_REPO_SECRET="${IMAGE_REPO_SECRET:-$DEFAULT_IMAGE_REPO_SECRET}"

# Image configuration (KMM_IMG_REPO default only applies on openshift)
if [ -z "${KMM_IMG_REPO:-}" ] && [ "${PLATFORM}" = "openshift" ]; then
    KMM_IMG_REPO="$DEFAULT_KMM_IMG_REPO"
fi
KMM_IMG_REPO="${KMM_IMG_REPO:-}"
KMM_PULL_SECRET="${KMM_PULL_SECRET:-}"

# Key file paths (can be overridden)
PRIVATE_KEY_FILE="${PRIVATE_KEY_FILE:-}"
PUBLIC_CERT_FILE="${PUBLIC_CERT_FILE:-}"

# KMM_IMG is what the kustomize templates actually reference.
KMM_IMG="${KMM_IMG:-}"

show_deployment_configuration() {
    show_configuration "Configuration" \
        "PLATFORM" \
        "KUBE_CMD" \
        "NAMESPACE" \
        "VASTNFS_VERSION" \
        "SIGNING_KEY_SECRET" \
        "SIGNING_CERT_SECRET" \
        "IMAGE_REPO_SECRET" \
        "KMM_IMG"
}

generate_keys() {
    if [ -n "$PRIVATE_KEY_FILE" ] && [ -n "$PUBLIC_CERT_FILE" ]; then
        print_step "Using provided key files..."
        check_file_exists "$PRIVATE_KEY_FILE" "Private key file"
        check_file_exists "$PUBLIC_CERT_FILE" "Public certificate file"
        return
    fi

    print_step "Generating secure boot keys..."

    KEY_DIR=$(mktemp -d)
    KEYS_DIR="$KEY_DIR" KEY_NAME="vastnfs_signing_key" "$SCRIPT_DIR/generate_secure_boot_keys.sh" --force

    PRIVATE_KEY_FILE="${KEY_DIR}/vastnfs_signing_key.priv"
    PUBLIC_CERT_FILE="${KEY_DIR}/vastnfs_signing_key.der"

    print_info "Keys generated using dedicated script"
    print_warning "IMPORTANT: Save these keys securely!"
    print_info "Private Key: ${PRIVATE_KEY_FILE}"
    print_info "Public Cert: ${PUBLIC_CERT_FILE}"
    echo ""
}

create_secrets() {
    print_step "Creating Kubernetes secrets..."

    create_namespace_if_not_exists "${NAMESPACE}"
    create_secret_from_file "${SIGNING_KEY_SECRET}"  "${NAMESPACE}" "key"  "${PRIVATE_KEY_FILE}"
    create_secret_from_file "${SIGNING_CERT_SECRET}" "${NAMESPACE}" "cert" "${PUBLIC_CERT_FILE}"

    print_info "Secrets created for module signing"
}

verify_keys() {
    print_step "Verifying keys..."
    verify_secret_content "${SIGNING_KEY_SECRET}"  "${NAMESPACE}" "key"  "grep -q 'BEGIN.*KEY'"
    verify_secret_content "${SIGNING_CERT_SECRET}" "${NAMESPACE}" "cert" "openssl x509 -inform der -text"
}

deploy_vastnfs() {
    print_step "Deploying VAST NFS with secure boot support..."

    export NAMESPACE
    export VASTNFS_VERSION
    export KMM_IMG
    export BUILD_IMAGE="${BUILD_IMAGE:-fedora:latest}"
    export SIGNING_KEY_SECRET
    export SIGNING_CERT_SECRET
    export IMAGE_REPO_SECRET

    local temp_manifest="/tmp/vastnfs-secure-boot.yaml"

    if [ -n "$KMM_PULL_SECRET" ]; then
        print_step "Validating pull secret..."
        if ! "${KUBE_CMD}" get secret "$KMM_PULL_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
            print_error "Pull secret '$KMM_PULL_SECRET' not found in namespace '$NAMESPACE'"
            print_error "Please create the secret first or remove KMM_PULL_SECRET variable"
            print_error "Example: ${KUBE_CMD} create secret docker-registry $KMM_PULL_SECRET --docker-server=... --docker-username=... --docker-password=... -n $NAMESPACE"
            exit 1
        fi
        print_success "Pull secret '$KMM_PULL_SECRET' found"
    fi

    print_info "Building manifests with kustomize..."
    local kustomize_cmd="${KUSTOMIZE:-kustomize}"

    # Resolve the with-pull-secret overlay path (new layout vs legacy alias).
    local pull_secret_dir=""
    if [ -d "$KUSTOMIZE_DIR/../with-pull-secret" ]; then
        pull_secret_dir="$KUSTOMIZE_DIR/../with-pull-secret"
    elif [ -d "$KUSTOMIZE_DIR/../overlays/with-pull-secret" ]; then
        pull_secret_dir="$KUSTOMIZE_DIR/../overlays/with-pull-secret"
    fi

    if [ -n "$KMM_PULL_SECRET" ]; then
        print_info "Using pull secret overlay: $KMM_PULL_SECRET (from $pull_secret_dir)"
        "$kustomize_cmd" build "$pull_secret_dir" \
            | envsubst '$NAMESPACE $VASTNFS_VERSION $KMM_IMG $BUILD_IMAGE $KMM_PULL_SECRET $SIGNING_KEY_SECRET $SIGNING_CERT_SECRET $IMAGE_REPO_SECRET' > "$temp_manifest"
    else
        print_info "No pull secret specified, using base configuration"
        "$kustomize_cmd" build "${KUSTOMIZE_DIR}" \
            | envsubst '$NAMESPACE $VASTNFS_VERSION $KMM_IMG $BUILD_IMAGE $SIGNING_KEY_SECRET $SIGNING_CERT_SECRET $IMAGE_REPO_SECRET' > "$temp_manifest"
    fi

    print_info "Applying to cluster..."
    "${KUBE_CMD}" apply -f "$temp_manifest"

    cleanup_temp_files "$temp_manifest"

    print_success "VAST NFS deployed with secure boot support"
}

monitor_deployment() {
    print_step "Monitoring deployment..."

    print_info "Module status:"
    "${KUBE_CMD}" get module vastnfs -n "${NAMESPACE}" 2>/dev/null || echo "Module not found yet"

    echo ""
    print_info "Pods:"
    "${KUBE_CMD}" get pods -n "${NAMESPACE}" 2>/dev/null || echo "No pods found yet"

    echo ""
    print_info "To monitor the deployment:"
    echo "  ${KUBE_CMD} get module vastnfs -n ${NAMESPACE} -w"
    echo "  ${KUBE_CMD} get pods -n ${NAMESPACE} -w"
    echo "  ${KUBE_CMD} logs -f -l kmm.node.kubernetes.io/module.name=vastnfs -n ${NAMESPACE}"
}

show_verification() {
    print_step "Verification commands:"
    echo ""
    echo "After deployment completes, verify VAST NFS is working:"
    echo ""
    echo "1. Check module status:"
    echo "   ${KUBE_CMD} get module vastnfs -n ${NAMESPACE}"
    echo ""
    echo "2. Verify VAST NFS is loaded on nodes:"
    if [ "${PLATFORM}" = "openshift" ]; then
        echo "   oc debug node/<node-name> -- chroot /host cat /sys/module/sunrpc/parameters/nfs_bundle_version"
    else
        echo "   kubectl debug node/<node-name> -it --image=busybox -- chroot /host cat /sys/module/sunrpc/parameters/nfs_bundle_version"
    fi
    echo ""
    echo "3. Run 'make verify-secure-boot' for platform-aware checks."
    echo ""
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Install VAST NFS KMM with secure boot support"
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -n, --namespace NAME          Kubernetes namespace (default: $NAMESPACE)"
    echo "  -v, --version VERSION         VAST NFS version (default: $VASTNFS_VERSION)"
    echo "  -d, --dir DIRECTORY           Kustomize directory (default: $KUSTOMIZE_DIR)"
    echo "  -f, --follow-logs             Follow pod logs after installation"
    echo "  --keys PRIVATE PUBLIC         Use existing key files for signing"
    echo ""
    echo "Environment Variables:"
    echo "  PLATFORM                      openshift | vanilla (default: auto-detected)"
    echo "  KUBE_CMD                      kubectl | oc (default: platform-based)"
    echo "  NAMESPACE                     Kubernetes namespace"
    echo "  VASTNFS_VERSION               VAST NFS version"
    echo "  KUSTOMIZE_DIR                 Kustomize directory"
    echo "  PRIVATE_KEY_FILE              Path to private key file"
    echo "  PUBLIC_CERT_FILE              Path to public certificate file"

    show_common_help_footer
}

# ---- Log following helpers -------------------------------------------------
wait_for_container_ready() {
    local namespace="$1"
    local pod="$2"
    local timeout=300
    local count=0

    print_info "Waiting for pod $pod to be ready..."

    while [ $count -lt $timeout ]; do
        local running_containers phase
        running_containers=$("${KUBE_CMD}" get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || echo "")
        phase=$("${KUBE_CMD}" get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [[ "$running_containers" == *"true"* ]] || [[ "$phase" == "Running" ]] \
           || "${KUBE_CMD}" logs "$pod" -n "$namespace" --tail=1 >/dev/null 2>&1; then
            print_success "Pod $pod is ready for log streaming"
            return 0
        fi

        print_info "Pod status: $phase, waiting... ($count/$timeout)"
        sleep 2
        count=$((count + 2))
    done

    print_warning "Timeout waiting for pod $pod to be ready, will try to get logs anyway"
    return 1
}

wait_for_pods() {
    local namespace="$1"
    local timeout=60
    local count=0

    print_step "Waiting for pods to start..."
    sleep 5

    while [ $count -lt $timeout ]; do
        local pods
        pods=$("${KUBE_CMD}" get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

        if [ -n "$pods" ]; then
            print_success "Found pods: $pods"
            return 0
        else
            if [ $((count % 10)) -eq 0 ]; then
                print_info "Waiting for pods to start... (${count}s elapsed)"
            fi
            sleep 2
            count=$((count + 2))
        fi
    done

    print_error "Timeout waiting for pods to start"
    return 1
}

follow_pod_logs() {
    local namespace="$1"
    print_step "Following pod logs..."

    local pods
    pods=$("${KUBE_CMD}" get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$pods" ]; then
        print_error "No pods found to follow logs"
        return 1
    fi

    print_info "Found pods: $pods"

    for pod in $pods; do
        print_info "=== Preparing to follow logs for $pod ==="
        wait_for_container_ready "$namespace" "$pod"
        print_info "Starting log stream for $pod..."

        {
            local retry_count=0
            while [ $retry_count -lt 10 ]; do
                if "${KUBE_CMD}" logs -f "$pod" -n "$namespace" --tail=50 2>/dev/null; then
                    break
                else
                    print_info "Retrying log stream for $pod... ($retry_count/10)"
                    sleep 3
                    retry_count=$((retry_count + 1))
                fi
            done
        } &
    done

    print_info "Log streaming started for all pods. Press Ctrl+C to stop."
    wait
}

# ---- CLI parsing -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)        show_help; exit 0 ;;
        -n|--namespace)   NAMESPACE="$2"; shift 2 ;;
        -v|--version)     VASTNFS_VERSION="$2"; shift 2 ;;
        -d|--dir)         KUSTOMIZE_DIR="$2"; shift 2 ;;
        -f|--follow-logs) FOLLOW_LOGS=true; shift ;;
        --keys)
            PRIVATE_KEY_FILE="$2"
            PUBLIC_CERT_FILE="$3"
            shift 3
            ;;
        *) print_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ---- Main ------------------------------------------------------------------
main() {
    print_header "VAST NFS KMM Deployment with Secure Boot Support"
    check_prerequisites
    check_cluster_connection

    if [ -z "$VASTNFS_VERSION" ]; then
        print_error "VASTNFS_VERSION environment variable not set"
        print_info "Please set VASTNFS_VERSION (e.g., export VASTNFS_VERSION=4.5.5)"
        exit 1
    fi

    # KMM_IMG_REPO is required on vanilla, has a default on openshift.
    if [ -z "$KMM_IMG_REPO" ]; then
        print_error "KMM_IMG_REPO environment variable not set"
        print_info "Please set KMM_IMG_REPO (e.g., export KMM_IMG_REPO=myregistry:5000/vastnfs)"
        exit 1
    fi

    # If KMM_IMG wasn't set (it usually is, from the Makefile), construct one.
    if [ -z "$KMM_IMG" ]; then
        KMM_IMG="${KMM_IMG_REPO}:\${KERNEL_FULL_VERSION}-vastnfs-${VASTNFS_VERSION}"
    fi

    show_deployment_configuration
    generate_keys
    create_secrets
    verify_keys
    deploy_vastnfs
    monitor_deployment

    if [ "$FOLLOW_LOGS" = "true" ]; then
        if wait_for_pods "$NAMESPACE"; then
            follow_pod_logs "$NAMESPACE"
        else
            print_warning "Could not wait for pods, skipping log following"
        fi
    fi

    show_verification

    echo ""
    print_success "VAST NFS deployment with secure boot support completed!"
    echo ""
    print_info "Next Steps:"
    print_info "1. The signed kernel modules are now being built and deployed to cluster nodes"
    print_info "2. After the build completes, DaemonSet pods will start on each node"
    print_info "3. Each node will then load the signed VAST NFS kernel modules (modprobe)"
    print_info ""
    print_warning "IMPORTANT: Wait approximately 2-3 minutes before running verification"
    print_info "   Secure boot builds take longer due to module signing."
    print_info ""
    print_info "To verify installation:"
    print_info "   make verify"
    print_info "   make verify-secure-boot"
    print_info ""
    print_warning "Secure Boot Important Notes:"
    print_info "1. Ensure the public key is enrolled in the MOK database on secure boot nodes"
    print_info "2. The signing process may take several minutes to complete"
    print_info ""
    print_info "For VAST NFS driver documentation:"
    print_info "   https://vastnfs.vastdata.com/docs/4.0/Intro.html"
    echo ""
}

main
