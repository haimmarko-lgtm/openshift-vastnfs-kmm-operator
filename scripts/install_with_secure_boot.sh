#!/usr/bin/env bash

# Single-entry VAST NFS KMM deployment with Secure Boot support.
#
# This script is intentionally resumable:
#   1. Prepare or reuse signing keys.
#   2. Create/update KMM signing secrets.
#   3. Stage MOK enrollment if Secure Boot nodes do not yet trust the cert.
#   4. Stop before deployment when a reboot/MokManager confirmation is needed.
#   5. On the next run, deploy the signed KMM Module once trust is in place.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=secure_boot_common.sh
source "${SCRIPT_DIR}/secure_boot_common.sh"

# ---- Configuration ---------------------------------------------------------
NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
VASTNFS_VERSION="${VASTNFS_VERSION:-}"
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-k8s/overlays/${PLATFORM}/secure-boot}"
FOLLOW_LOGS=false

SIGNING_KEY_SECRET="${SIGNING_KEY_SECRET:-$DEFAULT_SIGNING_KEY_SECRET}"
SIGNING_CERT_SECRET="${SIGNING_CERT_SECRET:-$DEFAULT_SIGNING_CERT_SECRET}"
IMAGE_REPO_SECRET="${IMAGE_REPO_SECRET:-$DEFAULT_IMAGE_REPO_SECRET}"

if [[ -z "${KMM_IMG_REPO:-}" && "${PLATFORM}" == "openshift" ]]; then
    KMM_IMG_REPO="$DEFAULT_KMM_IMG_REPO"
fi
KMM_IMG_REPO="${KMM_IMG_REPO:-}"
KMM_PULL_SECRET="${KMM_PULL_SECRET:-}"
KMM_IMG="${KMM_IMG:-}"

PRIVATE_KEY_FILE="${PRIVATE_KEY_FILE:-}"
PUBLIC_CERT_FILE="${PUBLIC_CERT_FILE:-}"
KEYS_DIR="${KEYS_DIR:-$DEFAULT_KEYS_DIR}"
KEY_NAME="${KEY_NAME:-$DEFAULT_KEY_NAME}"

NODE_SELECTOR="${NODE_SELECTOR:-}"
MOK_PASSWORD="${MOK_PASSWORD:-}"
MOK_PASSWORD_FILE="${MOK_PASSWORD_FILE:-}"
MOK_PROMPT_TIMEOUT="${MOK_PROMPT_TIMEOUT:-60}"
SKIP_SECURE_BOOT_KEY_ENROLLMENT_CHECK="${SKIP_SECURE_BOOT_KEY_ENROLLMENT_CHECK:-false}"
OVERWRITE_SIGNING_SECRETS=false
USING_SECRET_ONLY_KEYS=false

TEMP_CERT_FILE=""

cleanup() {
    if [[ -n "$TEMP_CERT_FILE" ]]; then
        cleanup_temp_files "$TEMP_CERT_FILE"
    fi
}
trap cleanup EXIT

show_deployment_configuration() {
    show_configuration "Configuration" \
        "PLATFORM" \
        "KUBE_CMD" \
        "NAMESPACE" \
        "VASTNFS_VERSION" \
        "KMM_IMG_REPO" \
        "KMM_IMG" \
        "KUSTOMIZE_DIR" \
        "SIGNING_KEY_SECRET" \
        "SIGNING_CERT_SECRET" \
        "KEYS_DIR" \
        "KEY_NAME" \
        "NODE_SELECTOR" \
        "MOK_PROMPT_TIMEOUT" \
        "SKIP_SECURE_BOOT_KEY_ENROLLMENT_CHECK"
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Install VAST NFS KMM with Secure Boot support."
    echo "This is a resumable flow: rerun the same command after MOK enrollment."
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -n, --namespace NAME          Kubernetes namespace (default: $NAMESPACE)"
    echo "  -v, --version VERSION         VAST NFS version"
    echo "  -d, --dir DIRECTORY           Kustomize directory (default: $KUSTOMIZE_DIR)"
    echo "  -f, --follow-logs             Follow pod logs after deployment"
    echo ""
    echo "Environment Variables:"
    echo "  PRIVATE_KEY_FILE              Existing signing private key"
    echo "  PUBLIC_CERT_FILE              Existing signing public DER certificate"
    echo "  KEYS_DIR                      Generated/reused keys directory (default: $KEYS_DIR)"
    echo "  KEY_NAME                      Generated/reused key prefix (default: $KEY_NAME)"
    echo "  MOK_PASSWORD_FILE             Preferred file containing one-time MOK password"
    echo "  MOK_PASSWORD                  One-time MOK password (lab convenience)"
    echo "  MOK_PROMPT_TIMEOUT            MokManager prompt timeout seconds (default: $MOK_PROMPT_TIMEOUT)"
    echo "  NODE_SELECTOR                 Optional node selector, e.g. vastnfs-kmm/enabled=true"
    echo "  SKIP_SECURE_BOOT_KEY_ENROLLMENT_CHECK=true"
    echo "                                Bypass trust preflight intentionally"
    show_common_help_footer
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        show_help; exit 0 ;;
        -n|--namespace)   NAMESPACE="$2"; shift 2 ;;
        -v|--version)     VASTNFS_VERSION="$2"; shift 2 ;;
        -d|--dir)         KUSTOMIZE_DIR="$2"; shift 2 ;;
        -f|--follow-logs) FOLLOW_LOGS=true; shift ;;
        *) print_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

read_mok_password() {
    if [[ -n "$MOK_PASSWORD" ]]; then
        return 0
    fi

    if [[ -n "$MOK_PASSWORD_FILE" ]]; then
        check_file_exists "$MOK_PASSWORD_FILE" "MOK password file"
        MOK_PASSWORD="$(awk 'NR == 1 { print; exit }' "$MOK_PASSWORD_FILE")"
    fi
}

prepare_signing_material() {
    print_step "Preparing Secure Boot signing material..."

    if [[ -n "$PRIVATE_KEY_FILE" || -n "$PUBLIC_CERT_FILE" ]]; then
        if [[ -z "$PRIVATE_KEY_FILE" || -z "$PUBLIC_CERT_FILE" ]]; then
            print_error "PRIVATE_KEY_FILE and PUBLIC_CERT_FILE must be provided together"
            exit 1
        fi

        check_file_exists "$PRIVATE_KEY_FILE" "Private key file"
        check_file_exists "$PUBLIC_CERT_FILE" "Public certificate file"
        OVERWRITE_SIGNING_SECRETS=true
        print_info "Using provided key files"
        print_info "Private Key: $PRIVATE_KEY_FILE"
        print_info "Public Cert: $PUBLIC_CERT_FILE"
        return 0
    fi

    local generated_private="${KEYS_DIR}/${KEY_NAME}.priv"
    local generated_cert="${KEYS_DIR}/${KEY_NAME}.der"

    if [[ -f "$generated_private" && -f "$generated_cert" ]]; then
        PRIVATE_KEY_FILE="$generated_private"
        PUBLIC_CERT_FILE="$generated_cert"
        OVERWRITE_SIGNING_SECRETS=true
        print_info "Using existing generated keys from $KEYS_DIR"
        print_info "Private Key: $PRIVATE_KEY_FILE"
        print_info "Public Cert: $PUBLIC_CERT_FILE"
        return 0
    fi

    if [[ -f "$generated_private" || -f "$generated_cert" ]]; then
        print_error "Only one generated key file exists in $KEYS_DIR"
        print_info "Expected both: $generated_private and $generated_cert"
        exit 1
    fi

    if check_secret_exists "$SIGNING_KEY_SECRET" "$NAMESPACE" \
        && check_secret_exists "$SIGNING_CERT_SECRET" "$NAMESPACE"; then
        USING_SECRET_ONLY_KEYS=true
        print_info "Using existing signing secrets in namespace $NAMESPACE"
        return 0
    fi

    if check_secret_exists "$SIGNING_KEY_SECRET" "$NAMESPACE" \
        || check_secret_exists "$SIGNING_CERT_SECRET" "$NAMESPACE"; then
        print_error "Only one signing secret exists in namespace $NAMESPACE"
        print_info "Expected both: $SIGNING_KEY_SECRET and $SIGNING_CERT_SECRET"
        print_info "Delete the stale secret or rerun with PRIVATE_KEY_FILE and PUBLIC_CERT_FILE."
        exit 1
    fi

    print_info "No signing keys or secrets found; generating reusable keys..."
    KEYS_DIR="$KEYS_DIR" KEY_NAME="$KEY_NAME" "$SCRIPT_DIR/generate_secure_boot_keys.sh"
    PRIVATE_KEY_FILE="$generated_private"
    PUBLIC_CERT_FILE="$generated_cert"
    OVERWRITE_SIGNING_SECRETS=true
    print_info "Private Key: $PRIVATE_KEY_FILE"
    print_info "Public Cert: $PUBLIC_CERT_FILE"
}

ensure_signing_secrets() {
    print_step "Ensuring Kubernetes signing secrets..."

    create_namespace_if_not_exists "$NAMESPACE"

    if [[ "$USING_SECRET_ONLY_KEYS" == "true" ]]; then
        print_info "Signing secrets already exist; leaving them unchanged"
    else
        create_secret_from_file "$SIGNING_KEY_SECRET" "$NAMESPACE" "key" "$PRIVATE_KEY_FILE" "$OVERWRITE_SIGNING_SECRETS"
        create_secret_from_file "$SIGNING_CERT_SECRET" "$NAMESPACE" "cert" "$PUBLIC_CERT_FILE" "$OVERWRITE_SIGNING_SECRETS"
    fi

    verify_secret_content "$SIGNING_KEY_SECRET" "$NAMESPACE" "key" "grep -q 'BEGIN.*KEY'"
    verify_secret_content "$SIGNING_CERT_SECRET" "$NAMESPACE" "cert" "openssl x509 -inform der -text"
}

resolve_public_cert_for_checks() {
    if [[ -n "$PUBLIC_CERT_FILE" && -f "$PUBLIC_CERT_FILE" ]]; then
        printf '%s\n' "$PUBLIC_CERT_FILE"
        return 0
    fi

    TEMP_CERT_FILE="$(mktemp)"
    "${KUBE_CMD}" get secret "$SIGNING_CERT_SECRET" -n "$NAMESPACE" \
        -o jsonpath='{.data.cert}' | base64 -d > "$TEMP_CERT_FILE"
    printf '%s\n' "$TEMP_CERT_FILE"
}

stage_mok_if_needed() {
    local cert_file="$1"
    local expected_sha1="$2"
    local nodes="$3"
    local staged_nodes=()
    local missing_password_nodes=()
    local node

    read_mok_password

    for node in $nodes; do
        if ! sb_is_secure_boot_enabled "$node"; then
            print_info "Node $node: Secure Boot disabled, MOK enrollment not required"
            continue
        fi

        if sb_node_has_cert_enrolled "$node" "$expected_sha1"; then
            print_info "Node $node: signing cert is enrolled"
            continue
        fi

        if sb_node_has_cert_pending "$node" "$expected_sha1"; then
            print_warning "Node $node: signing cert is pending MOK enrollment"
            staged_nodes+=("$node")
            continue
        fi

        if [[ -z "$MOK_PASSWORD" ]]; then
            print_warning "Node $node: signing cert is not enrolled and cannot be staged without MOK_PASSWORD_FILE or MOK_PASSWORD"
            missing_password_nodes+=("$node")
            continue
        fi

        print_step "Staging MOK enrollment on $node..."
        sb_stage_mok_enrollment "$node" "$cert_file" "$MOK_PASSWORD" "$MOK_PROMPT_TIMEOUT"

        if ! sb_node_has_cert_pending "$node" "$expected_sha1"; then
            print_error "Node $node: failed to verify pending MOK enrollment"
            print_info "Inspect manually: ${KUBE_CMD} debug node/${node} -- chroot /host mokutil --list-new"
            exit 1
        fi

        staged_nodes+=("$node")
    done

    if [[ ${#missing_password_nodes[@]} -gt 0 ]]; then
        print_error "Secure Boot signing cert is not trusted on: ${missing_password_nodes[*]}"
        print_info "Rerun with a one-time MOK password so the cert can be staged:"
        print_info "  make install-secure-boot VASTNFS_VERSION=${VASTNFS_VERSION} MOK_PASSWORD_FILE=/secure/mok-password"
        print_info "For lab use only:"
        print_info "  make install-secure-boot VASTNFS_VERSION=${VASTNFS_VERSION} MOK_PASSWORD='<one-time-password>'"
        exit 1
    fi

    if [[ ${#staged_nodes[@]} -gt 0 ]]; then
        echo ""
        print_success "MOK enrollment is pending on: ${staged_nodes[*]}"
        print_warning "Reboot each listed node and complete MokManager enrollment before deploying VAST NFS."
        print_info "At the MokManager screen: Enroll MOK -> Continue -> Yes -> enter the one-time password -> Reboot"
        print_info "After all nodes are enrolled, rerun the same install command:"
        print_info "  make install-secure-boot VASTNFS_VERSION=${VASTNFS_VERSION}"
        exit 0
    fi
}

verify_secure_boot_trust_or_stage() {
    if [[ "$SKIP_SECURE_BOOT_KEY_ENROLLMENT_CHECK" == "true" ]]; then
        print_warning "Skipping Secure Boot key enrollment check"
        return 0
    fi

    print_step "Inspecting Secure Boot node trust..."

    local cert_file expected_sha1 nodes
    cert_file=$(resolve_public_cert_for_checks)
    expected_sha1=$(sb_cert_sha1 "$cert_file")
    nodes=$(sb_target_nodes "$NODE_SELECTOR")

    if [[ -z "$nodes" ]]; then
        print_error "No target nodes found for Secure Boot checks"
        exit 1
    fi

    print_info "Signing cert SHA1: $expected_sha1"
    stage_mok_if_needed "$cert_file" "$expected_sha1" "$nodes"
    print_success "Signing cert enrollment verified on Secure Boot nodes"
}

cleanup_stale_kmm_state() {
    local namespace="$1"
    local module_name="vastnfs"

    print_step "Cleaning stale KMM generated state..."

    "${KUBE_CMD}" delete pods -n "$namespace" \
        -l "kmm.node.kubernetes.io/module.name=$module_name" \
        --ignore-not-found=true --wait=false >/dev/null 2>&1 || true

    "${KUBE_CMD}" delete nodemodulesconfig \
        -l "beta.kmm.node.kubernetes.io/${namespace}.${module_name}.module-configured" \
        --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    "${KUBE_CMD}" delete nodemodulesconfig \
        -l "beta.kmm.node.kubernetes.io/${namespace}.${module_name}.module-in-use" \
        --ignore-not-found=true --wait=false >/dev/null 2>&1 || true

    "${KUBE_CMD}" delete builds -n "$namespace" \
        -l "kmm.node.kubernetes.io/module.name=$module_name" \
        --ignore-not-found=true --wait=false >/dev/null 2>&1 || true

    "${KUBE_CMD}" patch modulebuildsignconfig "$module_name" -n "$namespace" \
        -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
    "${KUBE_CMD}" delete modulebuildsignconfig "$module_name" -n "$namespace" \
        --ignore-not-found=true >/dev/null 2>&1 || true

    "${KUBE_CMD}" patch moduleimagesconfig "$module_name" -n "$namespace" \
        -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
    "${KUBE_CMD}" delete moduleimagesconfig "$module_name" -n "$namespace" \
        --ignore-not-found=true >/dev/null 2>&1 || true

    if [[ "${PLATFORM}" == "openshift" && -n "${VASTNFS_VERSION:-}" ]]; then
        "${KUBE_CMD}" get imagestreamtag -n "$namespace" -o name 2>/dev/null \
            | while IFS= read -r image_tag; do
                case "$image_tag" in
                    imagestreamtag.image.openshift.io/vastnfs:*vastnfs-"$VASTNFS_VERSION"*)
                        "${KUBE_CMD}" delete "$image_tag" -n "$namespace" \
                            --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
                        ;;
                esac
            done
    fi
}

render_secure_boot_manifest() {
    local output_file="$1"
    local kustomize_cmd="${KUSTOMIZE:-kustomize}"
    local pull_secret_dir=""

    export NAMESPACE
    export VASTNFS_VERSION
    export KMM_IMG
    export BUILD_IMAGE="${BUILD_IMAGE:-fedora:latest}"
    export SIGNING_KEY_SECRET
    export SIGNING_CERT_SECRET
    export IMAGE_REPO_SECRET
    export KMM_PULL_SECRET

    if [[ -d "$KUSTOMIZE_DIR/../with-pull-secret" ]]; then
        pull_secret_dir="$KUSTOMIZE_DIR/../with-pull-secret"
    elif [[ -d "$KUSTOMIZE_DIR/../overlays/with-pull-secret" ]]; then
        pull_secret_dir="$KUSTOMIZE_DIR/../overlays/with-pull-secret"
    fi

    print_info "Building manifests with kustomize..."
    if [[ -n "$KMM_PULL_SECRET" ]]; then
        if [[ -z "$pull_secret_dir" ]]; then
            print_error "KMM_PULL_SECRET was set but no with-pull-secret overlay was found"
            exit 1
        fi
        "$kustomize_cmd" build "$pull_secret_dir" \
            | envsubst '$NAMESPACE $VASTNFS_VERSION $KMM_IMG $BUILD_IMAGE $KMM_PULL_SECRET $SIGNING_KEY_SECRET $SIGNING_CERT_SECRET $IMAGE_REPO_SECRET' > "$output_file"
    else
        "$kustomize_cmd" build "$KUSTOMIZE_DIR" \
            | envsubst '$NAMESPACE $VASTNFS_VERSION $KMM_IMG $BUILD_IMAGE $SIGNING_KEY_SECRET $SIGNING_CERT_SECRET $IMAGE_REPO_SECRET' > "$output_file"
    fi
}

deploy_vastnfs() {
    print_step "Deploying VAST NFS with Secure Boot signing..."

    if [[ -n "$KMM_PULL_SECRET" ]] && ! "${KUBE_CMD}" get secret "$KMM_PULL_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
        print_error "Pull secret '$KMM_PULL_SECRET' not found in namespace '$NAMESPACE'"
        exit 1
    fi

    local temp_manifest
    temp_manifest=$(mktemp)
    render_secure_boot_manifest "$temp_manifest"

    print_info "Applying to cluster..."
    cleanup_stale_kmm_state "$NAMESPACE"
    "${KUBE_CMD}" apply -f "$temp_manifest"
    refresh_openshift_kmm_worker_pods "$NAMESPACE" "vastnfs-kmm-sa" "vastnfs"
    cleanup_temp_files "$temp_manifest"

    print_success "VAST NFS deployed with Secure Boot support"
}

monitor_deployment() {
    print_step "Monitoring deployment..."
    print_info "Module status:"
    "${KUBE_CMD}" get module vastnfs -n "$NAMESPACE" 2>/dev/null || echo "Module not found yet"

    echo ""
    print_info "Pods:"
    "${KUBE_CMD}" get pods -n "$NAMESPACE" 2>/dev/null || echo "No pods found yet"

    echo ""
    print_info "To monitor manually:"
    echo "  ${KUBE_CMD} get module vastnfs -n ${NAMESPACE} -w"
    echo "  ${KUBE_CMD} get pods -n ${NAMESPACE} -w"
    echo "  ${KUBE_CMD} logs -f -l kmm.node.kubernetes.io/module.name=vastnfs -n ${NAMESPACE}"
}

wait_for_container_ready() {
    local namespace="$1"
    local pod="$2"
    local timeout=300
    local count=0

    print_info "Waiting for pod $pod to be ready..."
    while [[ $count -lt $timeout ]]; do
        local running_containers phase
        running_containers=$("${KUBE_CMD}" get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || echo "")
        phase=$("${KUBE_CMD}" get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [[ "$running_containers" == *"true"* || "$phase" == "Running" ]] \
           || "${KUBE_CMD}" logs "$pod" -n "$namespace" --tail=1 >/dev/null 2>&1; then
            print_success "Pod $pod is ready for log streaming"
            return 0
        fi

        sleep 2
        count=$((count + 2))
    done

    print_warning "Timeout waiting for pod $pod to be ready, will try logs anyway"
    return 1
}

wait_for_pods() {
    local namespace="$1"
    local timeout=60
    local count=0

    print_step "Waiting for pods to start..."
    sleep 5
    while [[ $count -lt $timeout ]]; do
        local pods
        pods=$("${KUBE_CMD}" get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$pods" ]]; then
            print_success "Found pods: $pods"
            return 0
        fi
        sleep 2
        count=$((count + 2))
    done

    print_error "Timeout waiting for pods to start"
    return 1
}

follow_pod_logs() {
    local namespace="$1"
    local pods

    print_step "Following pod logs..."
    pods=$("${KUBE_CMD}" get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pods" ]]; then
        print_error "No pods found to follow logs"
        return 1
    fi

    for pod in $pods; do
        print_info "=== Preparing to follow logs for $pod ==="
        wait_for_container_ready "$namespace" "$pod"
        {
            local retry_count=0
            while [[ $retry_count -lt 10 ]]; do
                if "${KUBE_CMD}" logs -f "$pod" -n "$namespace" --tail=50 2>/dev/null; then
                    break
                fi
                sleep 3
                retry_count=$((retry_count + 1))
            done
        } &
    done

    print_info "Log streaming started for all pods. Press Ctrl+C to stop."
    wait
}

show_verification() {
    print_step "Verification commands:"
    echo "  make verify"
    echo "  make verify-secure-boot"
    echo "  ${KUBE_CMD} get module vastnfs -n ${NAMESPACE}"
}

main() {
    print_header "VAST NFS KMM Secure Boot Installation"
    check_prerequisites
    check_openssl
    check_cluster_connection

    if [[ -z "$VASTNFS_VERSION" ]]; then
        print_error "VASTNFS_VERSION environment variable not set"
        print_info "Example: make install-secure-boot VASTNFS_VERSION=4.5.5"
        exit 1
    fi

    if [[ -z "$KMM_IMG_REPO" ]]; then
        print_error "KMM_IMG_REPO environment variable not set"
        print_info "Example: KMM_IMG_REPO=myregistry:5000/vastnfs make install-secure-boot VASTNFS_VERSION=4.5.5"
        exit 1
    fi

    if [[ -z "$KMM_IMG" ]]; then
        KMM_IMG="${KMM_IMG_REPO}:\${KERNEL_FULL_VERSION}-vastnfs-${VASTNFS_VERSION}-secureboot"
    fi

    show_deployment_configuration
    prepare_signing_material
    ensure_signing_secrets
    verify_secure_boot_trust_or_stage
    deploy_vastnfs
    monitor_deployment

    if [[ "$FOLLOW_LOGS" == "true" ]]; then
        if wait_for_pods "$NAMESPACE"; then
            follow_pod_logs "$NAMESPACE"
        else
            print_warning "Could not wait for pods, skipping log following"
        fi
    fi

    show_verification
    print_success "Secure Boot installation flow completed"
}

main
