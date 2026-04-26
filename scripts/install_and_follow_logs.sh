#!/usr/bin/env bash

# Install VAST NFS KMM and optionally follow pod logs.
#
# Platform-aware:
#   - Uses ${KUBE_CMD} (default: oc on openshift, kubectl on vanilla).
#   - For on-node version checks, uses `oc debug node/...` on openshift
#     if oc is available, or a `kubectl run` host-path probe pod otherwise.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---- Configuration ---------------------------------------------------------
NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
VASTNFS_VERSION="${VASTNFS_VERSION:-}"
KMM_IMG="${KMM_IMG:-}"
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-k8s/overlays/${PLATFORM}/base}"
FOLLOW_LOGS=false

# On OpenShift `oc debug node` is the preferred node-inspection mechanism.
USE_OC_DEBUG=false
if [[ "${PLATFORM}" == "openshift" ]] && command -v oc >/dev/null 2>&1; then
    USE_OC_DEBUG=true
fi

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Install VAST NFS KMM and optionally follow logs"
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -n, --namespace NAME          Kubernetes namespace (default: $NAMESPACE)"
    echo "  -v, --version VERSION         VAST NFS version (required)"
    echo "  -i, --image IMAGE             KMM image (required or set KMM_IMG_REPO)"
    echo "  -d, --dir DIRECTORY           Kustomize directory (default: $KUSTOMIZE_DIR)"
    echo "  -f, --follow-logs             Follow pod logs after installation"
    echo ""
    echo "Required Environment Variables:"
    echo "  VASTNFS_VERSION               VAST NFS version (e.g., 4.5.5)"
    echo "  KMM_IMG or KMM_IMG_REPO       KMM image or registry"
    echo ""
    echo "Optional Environment Variables:"
    echo "  PLATFORM                      openshift | vanilla (default: auto-detected)"
    echo "  KUBE_CMD                      kubectl | oc (default: platform-based)"
    echo "  NAMESPACE                     Kubernetes namespace (default: $DEFAULT_NAMESPACE)"
    echo "  KUSTOMIZE_DIR                 Kustomize directory"
    echo "  NODE_SELECTOR                 key=value[,key2=value2] label selector to patch onto the Module"

    show_common_help_footer
}

# ---- Install ---------------------------------------------------------------
cleanup_stale_kmm_state() {
    local namespace="$1"
    local module_name="vastnfs"

    print_step "Cleaning stale KMM generated state..."

    "${KUBE_CMD}" delete pods -n "$namespace" \
        -l "kmm.node.kubernetes.io/module.name=$module_name" \
        --ignore-not-found=true >/dev/null 2>&1 || true

    "${KUBE_CMD}" delete builds -n "$namespace" \
        -l "kmm.node.kubernetes.io/module.name=$module_name" \
        --ignore-not-found=true >/dev/null 2>&1 || true

    "${KUBE_CMD}" patch modulebuildsignconfig "$module_name" -n "$namespace" \
        -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
    "${KUBE_CMD}" delete modulebuildsignconfig "$module_name" -n "$namespace" \
        --ignore-not-found=true >/dev/null 2>&1 || true

    "${KUBE_CMD}" patch moduleimagesconfig "$module_name" -n "$namespace" \
        -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
    "${KUBE_CMD}" delete moduleimagesconfig "$module_name" -n "$namespace" \
        --ignore-not-found=true >/dev/null 2>&1 || true
}

install_vastnfs() {
    local namespace="$1"
    local vastnfs_version="$2"
    local kmm_img="$3"
    local kustomize_dir="$4"

    print_step "Installing VAST NFS KMM to namespace: $namespace"
    print_info "Platform:            $PLATFORM"
    print_info "Kube CLI:            $KUBE_CMD"
    print_info "VAST NFS Version:    $vastnfs_version"
    print_info "KMM Image:           $kmm_img"
    print_info "Kustomize Directory: $kustomize_dir"

    export VASTNFS_VERSION="$vastnfs_version"
    export KMM_IMG="$kmm_img"
    export NAMESPACE="$namespace"
    export KMM_PULL_SECRET="${KMM_PULL_SECRET:-}"
    # BUILD_IMAGE is consumed by the vanilla Dockerfile template; envsubst
    # passes it through harmlessly on OpenShift (DTK Dockerfile ignores it).
    export BUILD_IMAGE="${BUILD_IMAGE:-fedora:latest}"

    # Validate pull secret if provided
    if [ -n "$KMM_PULL_SECRET" ]; then
        print_step "Validating pull secret..."
        if ! "${KUBE_CMD}" get secret "$KMM_PULL_SECRET" -n "$namespace" >/dev/null 2>&1; then
            print_error "Pull secret '$KMM_PULL_SECRET' not found in namespace '$namespace'"
            print_error "Please create the secret first or remove KMM_PULL_SECRET variable"
            print_error "Example: ${KUBE_CMD} create secret docker-registry $KMM_PULL_SECRET --docker-server=... --docker-username=... --docker-password=... -n $namespace"
            return 1
        fi
        print_success "Pull secret '$KMM_PULL_SECRET' found"
    fi

    print_info "Building and applying manifests..."
    cleanup_stale_kmm_state "$namespace"

    local temp_manifest="/tmp/vastnfs-install-$$.yaml"
    local kustomize_cmd="${KUSTOMIZE:-kustomize}"

    # Resolve the with-pull-secret overlay path relative to the base dir.
    # - New layout: sibling (k8s/overlays/<platform>/base -> ../with-pull-secret).
    # - Legacy layout: k8s/base -> ../overlays/with-pull-secret.
    local pull_secret_dir=""
    if [ -d "$kustomize_dir/../with-pull-secret" ]; then
        pull_secret_dir="$kustomize_dir/../with-pull-secret"
    elif [ -d "$kustomize_dir/../overlays/with-pull-secret" ]; then
        pull_secret_dir="$kustomize_dir/../overlays/with-pull-secret"
    fi

    if [ -n "$KMM_PULL_SECRET" ]; then
        print_info "Using pull secret overlay: $KMM_PULL_SECRET (from $pull_secret_dir)"
        "$kustomize_cmd" build "$pull_secret_dir" \
            | envsubst '$VASTNFS_VERSION $KMM_IMG $NAMESPACE $KMM_PULL_SECRET $BUILD_IMAGE' > "$temp_manifest"
    else
        print_info "No pull secret specified, using base configuration"
        "$kustomize_cmd" build "$kustomize_dir" \
            | envsubst '$VASTNFS_VERSION $KMM_IMG $NAMESPACE $BUILD_IMAGE' > "$temp_manifest"
    fi

    if "${KUBE_CMD}" apply -f "$temp_manifest"; then
        rm -f "$temp_manifest"
        print_success "VAST NFS KMM installed successfully"

        # Apply node selector if specified
        if [ -n "${NODE_SELECTOR:-}" ]; then
            print_step "Applying node selector: $NODE_SELECTOR"
            local selector_json="{"
            local first=true
            IFS=',' read -ra SELECTORS <<< "$NODE_SELECTOR"
            for sel in "${SELECTORS[@]}"; do
                [ -z "$sel" ] && continue
                if [[ "$sel" == !* ]]; then
                    print_warning "Negation selectors (!key) not supported in simple mode. Use positive labels instead."
                    continue
                fi
                local key="${sel%%=*}"
                local value="${sel#*=}"
                if [ "$first" = true ]; then
                    first=false
                else
                    selector_json+=","
                fi
                selector_json+="\"$key\":\"$value\""
            done
            selector_json+="}"

            if [ "$selector_json" != "{}" ]; then
                "${KUBE_CMD}" patch module vastnfs -n "$namespace" --type=merge \
                    -p "{\"spec\":{\"selector\":$selector_json}}" 2>/dev/null || {
                    print_warning "Could not apply node selector (Module may not exist yet)"
                }
                print_success "Node selector applied"
            fi
        fi

        return 0
    else
        rm -f "$temp_manifest"
        print_error "Failed to install VAST NFS KMM"
        return 1
    fi
}

# ---- Node version check (platform-aware) ----------------------------------
check_vastnfs_version_on_node_openshift() {
    local node="$1"
    oc debug "node/${node}" -- chroot /host bash -c '
        if [[ -e /sys/module/sunrpc/parameters/nfs_bundle_version ]]; then
            cat /sys/module/sunrpc/parameters/nfs_bundle_version
        fi
    ' 2>&1 | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" | head -1
}

check_vastnfs_version_on_node_vanilla() {
    local node="$1"
    local pod_name="vastnfs-ver-${node//[^a-z0-9-]/-}-$(date +%s)"
    "${KUBE_CMD}" run "$pod_name" -n "$NAMESPACE" --rm -i --restart=Never \
        --image=busybox \
        --overrides='{
            "spec": {
                "nodeName": "'"$node"'",
                "hostPID": true,
                "containers": [{
                    "name": "check",
                    "image": "busybox",
                    "command": ["sh", "-c", "if [ -e /host-sys/module/sunrpc/parameters/nfs_bundle_version ]; then cat /host-sys/module/sunrpc/parameters/nfs_bundle_version; fi"],
                    "volumeMounts": [{
                        "name": "host-sys",
                        "mountPath": "/host-sys",
                        "readOnly": true
                    }]
                }],
                "volumes": [{
                    "name": "host-sys",
                    "hostPath": {
                        "path": "/sys",
                        "type": "Directory"
                    }
                }],
                "tolerations": [{"operator": "Exists"}]
            }
        }' 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" | head -1
}

check_vastnfs_version() {
    local expected_version="$1"
    local nodes
    nodes=$("${KUBE_CMD}" get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    for node in $nodes; do
        local version
        if [ "${USE_OC_DEBUG}" = "true" ]; then
            version=$(check_vastnfs_version_on_node_openshift "$node")
        else
            version=$(check_vastnfs_version_on_node_vanilla "$node")
        fi

        if [[ "$version" == "$expected_version" ]]; then
            return 0
        fi
    done

    return 1
}

# ---- Wait / follow-logs helpers -------------------------------------------
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
                if check_vastnfs_version "$VASTNFS_VERSION" 2>/dev/null; then
                    print_success "VAST NFS version $VASTNFS_VERSION is already active - pods completed successfully"
                    return 0
                fi
            fi
            sleep 2
            count=$((count + 2))
        fi
    done

    if check_vastnfs_version "$VASTNFS_VERSION" 2>/dev/null; then
        print_success "VAST NFS version $VASTNFS_VERSION is active - installation successful"
        return 0
    fi

    print_error "Timeout waiting for pods to start"
    return 1
}

wait_for_container_ready() {
    local namespace="$1"
    local pod="$2"
    local timeout=30
    local count=0

    print_info "Waiting for pod $pod to be ready..."

    while [ $count -lt $timeout ]; do
        if ! "${KUBE_CMD}" get pod "$pod" -n "$namespace" >/dev/null 2>&1; then
            print_info "Pod $pod no longer exists - it completed successfully"
            return 1
        fi

        local phase
        phase=$("${KUBE_CMD}" get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [[ "$phase" == "Succeeded" ]]; then
            print_success "Pod $pod completed successfully"
            return 1
        elif [[ "$phase" == "Failed" ]]; then
            print_warning "Pod $pod failed"
            return 0
        fi

        local running_containers
        running_containers=$("${KUBE_CMD}" get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || echo "")

        if [[ "$running_containers" == *"true"* ]] || [[ "$phase" == "Running" ]] \
            || "${KUBE_CMD}" logs "$pod" -n "$namespace" --tail=1 >/dev/null 2>&1; then
            print_success "Pod $pod is ready for log streaming"
            return 0
        fi

        if [ $((count % 10)) -eq 0 ]; then
            print_info "Pod status: $phase, waiting... ($count/$timeout)"
        fi

        sleep 2
        count=$((count + 2))
    done

    print_info "Pod may have completed too quickly to stream logs"
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

    local pods_to_follow=()

    for pod in $pods; do
        print_info "=== Preparing to follow logs for $pod ==="
        if wait_for_container_ready "$namespace" "$pod"; then
            pods_to_follow+=("$pod")
        else
            print_info "Pod $pod completed too quickly to stream logs (this is normal with pre-built images)"
        fi
    done

    if [ ${#pods_to_follow[@]} -eq 0 ]; then
        print_success "All pods completed successfully"
        return 0
    fi

    for pod in "${pods_to_follow[@]}"; do
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
        -h|--help)           show_help; exit 0 ;;
        -n|--namespace)      NAMESPACE="$2"; shift 2 ;;
        -v|--version)        VASTNFS_VERSION="$2"; shift 2 ;;
        -i|--image)          KMM_IMG="$2"; shift 2 ;;
        -d|--dir)            KUSTOMIZE_DIR="$2"; shift 2 ;;
        -f|--follow-logs)    FOLLOW_LOGS=true; shift ;;
        *) print_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ---- Main ------------------------------------------------------------------
main() {
    print_header "VAST NFS KMM Installation"

    check_prerequisites
    check_cluster_connection

    if [ -z "$VASTNFS_VERSION" ]; then
        print_error "VASTNFS_VERSION environment variable not set"
        print_info "Please set VASTNFS_VERSION (e.g., export VASTNFS_VERSION=4.5.5)"
        exit 1
    fi

    if [ -z "$KMM_IMG" ]; then
        print_error "KMM_IMG environment variable not set"
        print_info "Please set KMM_IMG or use the Makefile which sets it automatically"
        exit 1
    fi

    show_configuration "Installation Configuration" \
        "PLATFORM" "KUBE_CMD" "NAMESPACE" "VASTNFS_VERSION" "KMM_IMG" "KUSTOMIZE_DIR"

    if ! install_vastnfs "$NAMESPACE" "$VASTNFS_VERSION" "$KMM_IMG" "$KUSTOMIZE_DIR"; then
        exit 1
    fi

    if [ "$FOLLOW_LOGS" = "true" ]; then
        if wait_for_pods "$NAMESPACE"; then
            follow_pod_logs "$NAMESPACE"
        else
            print_warning "Could not wait for pods, skipping log following"
        fi
    fi

    print_success "VAST NFS KMM installation completed"

    echo ""
    print_info "Next Steps:"
    print_info "1. The kernel modules are now being built and deployed to cluster nodes"
    print_info "2. After the build completes, DaemonSet pods will start on each node"
    print_info "3. Each node will then load the VAST NFS kernel modules (modprobe)"
    print_info ""
    print_warning "IMPORTANT: Wait approximately 1-2 minutes before running verification"
    print_info "   This allows time for:"
    print_info "   - Module compilation to complete"
    print_info "   - DaemonSet pods to start on all nodes"
    print_info "   - Kernel modules to be loaded via modprobe"
    print_info ""
    print_info "To verify installation:"
    print_info "   make verify"
    print_info ""
    print_info "For VAST NFS driver documentation:"
    print_info "   https://vastnfs.vastdata.com/docs/4.0/Intro.html"
}

main "$@"
