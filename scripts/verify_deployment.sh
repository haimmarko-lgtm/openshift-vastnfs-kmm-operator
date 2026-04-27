#!/bin/bash

# VAST NFS Deployment Verification Script (platform-aware)
# Verifies that VAST NFS is properly deployed and working on every node.
#
# Usage:
#   ./verify_deployment.sh                    # Compact table output
#   VERBOSE=true ./verify_deployment.sh       # Detailed output
#   ./verify_deployment.sh --node <name>      # Restrict to a single node
#
# Platform selection is driven by scripts/common.sh (PLATFORM / KUBE_CMD).
# Node-level probing uses `oc debug node` on OpenShift when `KUBE_CMD=oc`,
# and falls back to a short-lived privileged pod (busybox +
# nsenter / hostPath) on vanilla Kubernetes.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

NAMESPACE=${NAMESPACE:-$DEFAULT_NAMESPACE}
MODULE_NAME=${MODULE_NAME:-vastnfs}
VERBOSE=${VERBOSE:-false}
NODE_FILTER=""

# When set, skip the `oc debug node` fast path and always use the pod-based
# fallback (useful when `oc` is on PATH but the user lacks permission to
# run node debug pods).
USE_POD_NODE_PROBE=${USE_POD_NODE_PROBE:-false}

_use_oc_debug() {
    if [ "${USE_POD_NODE_PROBE}" = "true" ]; then
        return 1
    fi
    if [ "${PLATFORM:-}" = "openshift" ] && [ "${KUBE_CMD:-}" = "oc" ] && command -v oc >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

check_verify_prerequisites() {
    if [[ "$VERBOSE" == "true" ]]; then
        print_step "Checking prerequisites..."
    fi

    if ! command -v "${KUBE_CMD}" &>/dev/null; then
        print_error "${KUBE_CMD} not found"
        print_info "Please install ${KUBE_CMD}"
        return 1
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        print_info "${KUBE_CMD}: $(${KUBE_CMD} version --client --short 2>/dev/null || ${KUBE_CMD} version --client -o json 2>/dev/null | grep -o '"gitVersion": "[^"]*"' | head -1)"
        print_info "platform: ${PLATFORM}"
    fi
    return 0
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Verify VAST NFS deployment status"
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -n, --namespace NAME          Kubernetes namespace (default: $DEFAULT_NAMESPACE)"
    echo "  -m, --module NAME             Module name (default: vastnfs)"
    echo "  -v, --verbose                 Show detailed output"
    echo "  -w, --wait SECONDS            Wait for module to be ready (default: no wait)"
    echo "  --node NODE                   Show status for a single node only"
    echo ""
    echo "Environment Variables:"
    echo "  NAMESPACE                     Kubernetes namespace"
    echo "  MODULE_NAME                   Module name to verify"
    echo "  VERBOSE=true                  Show detailed output"
    echo "  PLATFORM=openshift|vanilla    Override platform auto-detection"
    echo "  USE_POD_NODE_PROBE=true       Force pod-based probing even on OpenShift"
    echo ""
    echo "Examples:"
    echo "  $0                            Show compact table for all nodes"
    echo "  $0 --node worker-1            Show status for worker-1 only"
    echo "  VERBOSE=true $0               Show detailed output for all nodes"

    show_common_help_footer
}

# ============================================================================
# Helper Functions
# ============================================================================

is_control_plane_only() {
    local node="$1"
    local has_control_plane_taint
    has_control_plane_taint=$("${KUBE_CMD}" get node "$node" -o jsonpath='{.spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")].effect}' 2>/dev/null)
    if [[ "$has_control_plane_taint" == *"NoSchedule"* ]]; then
        return 0
    fi
    return 1
}

get_node_role() {
    local node="$1"
    local roles
    roles=$("${KUBE_CMD}" get node "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null)
    if echo "$roles" | grep -q "node-role.kubernetes.io/worker"; then
        if echo "$roles" | grep -q "node-role.kubernetes.io/control-plane\|node-role.kubernetes.io/master"; then
            echo "ctrl+worker"
        else
            echo "worker"
        fi
    elif echo "$roles" | grep -q "node-role.kubernetes.io/control-plane\|node-role.kubernetes.io/master"; then
        echo "control-plane"
    else
        echo "worker"
    fi
}

get_node_status() {
    local node="$1"
    local ready_status=""

    if "${KUBE_CMD}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
        ready_status="Ready"
    else
        ready_status="NotReady"
    fi

    local unschedulable
    unschedulable=$("${KUBE_CMD}" get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)
    if [[ "$unschedulable" == "true" ]]; then
        echo "${ready_status},Cord"
    else
        echo "$ready_status"
    fi
}

is_kmm_enabled() {
    local node="$1"
    local enabled_label
    enabled_label=$("${KUBE_CMD}" get node "$node" -o jsonpath='{.metadata.labels.vastnfs-kmm/enabled}' 2>/dev/null)
    if [[ "$enabled_label" == "true" ]]; then
        return 0
    fi
    return 1
}

get_kmm_status() {
    local node="$1"
    local role="$2"

    if [[ "$role" == "control-plane" ]] && is_control_plane_only "$node"; then
        echo "N/A"
        return
    fi

    # On OpenShift without explicit opt-in labelling, the module targets all
    # worker nodes by default, so treat an absent label as "Managed".
    if [[ "${PLATFORM:-}" == "openshift" ]]; then
        echo "Managed"
        return
    fi

    if is_kmm_enabled "$node"; then
        echo "Managed"
    else
        echo "Skipped"
    fi
}

get_node_os() {
    local node="$1"
    local os_image
    os_image=$("${KUBE_CMD}" get node "$node" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null)
    if [[ "$os_image" == *"Ubuntu"* ]]; then
        echo "$os_image" | grep -oE 'Ubuntu [0-9]+\.[0-9]+' | head -1
    elif [[ "$os_image" == *"Rocky"* ]]; then
        echo "$os_image" | grep -oE 'Rocky Linux [0-9]+\.[0-9]+' | head -1 | sed 's/Linux //'
    elif [[ "$os_image" == *"Red Hat Enterprise Linux CoreOS"* ]] || [[ "$os_image" == *"RHCOS"* ]]; then
        echo "$os_image" | grep -oE '[0-9]+\.[0-9]+' | head -1 | sed 's/^/RHCOS /'
    elif [[ "$os_image" == *"Red Hat"* ]] || [[ "$os_image" == *"RHEL"* ]]; then
        echo "$os_image" | grep -oE '[0-9]+\.[0-9]+' | head -1 | sed 's/^/RHEL /'
    elif [[ "$os_image" == *"CentOS"* ]]; then
        echo "$os_image" | grep -oE 'CentOS[^0-9]*[0-9]+' | head -1
    elif [[ "$os_image" == *"Debian"* ]]; then
        echo "$os_image" | grep -oE 'Debian[^0-9]*[0-9]+' | head -1
    elif [[ "$os_image" == *"Flatcar"* ]]; then
        echo "Flatcar"
    elif [[ "$os_image" == *"CoreOS"* ]]; then
        echo "CoreOS"
    else
        echo "${os_image:0:15}"
    fi
}

get_node_kernel() {
    local node="$1"
    "${KUBE_CMD}" get node "$node" -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null
}

# ----------------------------------------------------------------------------
# Node-level probing (platform-aware)
# ----------------------------------------------------------------------------

_probe_node_vastnfs_openshift() {
    local node="$1"
    "${KUBE_CMD}" debug "node/${node}" -- chroot /host bash -c '
        if [[ -e /sys/module/sunrpc/parameters/nfs_bundle_git_version ]]; then
            cat /sys/module/sunrpc/parameters/nfs_bundle_git_version
        elif [[ -e /sys/module/sunrpc/parameters/nfs_bundle_version ]]; then
            cat /sys/module/sunrpc/parameters/nfs_bundle_version
        else
            echo NOT_FOUND
        fi
    ' 2>/dev/null | tr -d '[:space:]' || echo ""
}

_probe_node_vastnfs_vanilla() {
    local node="$1"
    local pod_name="vastnfs-verify-${node//[^a-z0-9-]/-}-$(date +%s)"
    local version=""

    "${KUBE_CMD}" run "$pod_name" -n "$NAMESPACE" \
        --image=busybox \
        --restart=Never \
        --overrides='{
            "spec": {
                "nodeName": "'"$node"'",
                "hostPID": true,
                "containers": [{
                    "name": "check",
                    "image": "busybox",
                    "command": ["sh", "-c", "if [ -f /host-sys/module/sunrpc/parameters/nfs_bundle_git_version ]; then cat /host-sys/module/sunrpc/parameters/nfs_bundle_git_version; elif [ -f /host-sys/module/sunrpc/parameters/nfs_bundle_version ]; then cat /host-sys/module/sunrpc/parameters/nfs_bundle_version; else echo NOT_FOUND; fi"],
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
        }' &>/dev/null

    local timeout=30
    local count=0
    while [[ $count -lt $timeout ]]; do
        local phase
        phase=$("${KUBE_CMD}" get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "$phase" == "Succeeded" ]] || [[ "$phase" == "Failed" ]]; then
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    if [[ $count -lt $timeout ]]; then
        version=$("${KUBE_CMD}" logs "$pod_name" -n "$NAMESPACE" 2>/dev/null | tr -d '[:space:]')
    fi

    "${KUBE_CMD}" delete pod "$pod_name" -n "$NAMESPACE" --force --grace-period=0 &>/dev/null || true
    echo "$version"
}

check_node_vastnfs_status() {
    local node="$1"
    local version

    if _use_oc_debug; then
        version=$(_probe_node_vastnfs_openshift "$node")
    else
        version=$(_probe_node_vastnfs_vanilla "$node")
    fi

    if [[ -z "$version" ]] || [[ "$version" == "NOT_FOUND" ]]; then
        echo "not_active"
    else
        echo "$version"
    fi
}

# ----------------------------------------------------------------------------
# Secure boot probing (platform-aware)
# ----------------------------------------------------------------------------

_probe_signature_openshift() {
    local node="$1"
    "${KUBE_CMD}" debug "node/${node}" -- chroot /host modinfo sunrpc 2>/dev/null | grep -E "^signature:" | head -1 || echo ""
}

_probe_sb_state_openshift() {
    local node="$1"
    "${KUBE_CMD}" debug "node/${node}" -- chroot /host bash -c '
        if command -v mokutil >/dev/null 2>&1; then
            mokutil --sb-state 2>/dev/null
        else
            echo NOT_AVAILABLE
        fi
    ' 2>/dev/null | head -1 || echo ""
}

_probe_signature_vanilla() {
    local node="$1"
    local pod_name="sb-check-${node//[^a-z0-9-]/-}-$(date +%s)"
    "${KUBE_CMD}" run "$pod_name" -n "$NAMESPACE" --rm -i --restart=Never \
        --image=busybox \
        --overrides='{
            "spec": {
                "nodeName": "'"$node"'",
                "hostPID": true,
                "containers": [{
                    "name": "check",
                    "image": "busybox",
                    "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "modinfo", "sunrpc"],
                    "securityContext": {"privileged": true}
                }],
                "tolerations": [{"operator": "Exists"}]
            }
        }' 2>&1 | grep -E "^signature:" | head -1 || echo ""
}

_probe_sb_state_vanilla() {
    local node="$1"
    local pod_name="sb-state-${node//[^a-z0-9-]/-}-$(date +%s)"
    "${KUBE_CMD}" run "$pod_name" -n "$NAMESPACE" --rm -i --restart=Never \
        --image=busybox \
        --overrides='{
            "spec": {
                "nodeName": "'"$node"'",
                "hostPID": true,
                "containers": [{
                    "name": "check",
                    "image": "busybox",
                    "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "sh", "-c",
                        "if command -v mokutil >/dev/null 2>&1; then mokutil --sb-state 2>/dev/null; else echo NOT_AVAILABLE; fi"],
                    "securityContext": {"privileged": true}
                }],
                "tolerations": [{"operator": "Exists"}]
            }
        }' 2>&1 | grep -v "^pod \|^If you don" | head -1 || echo ""
}

get_secure_boot_status() {
    local node="$1"
    local sb_state

    if _use_oc_debug; then
        sb_state=$(_probe_sb_state_openshift "$node")
    else
        sb_state=$(_probe_sb_state_vanilla "$node")
    fi

    if [[ "$sb_state" == "NOT_AVAILABLE" ]] || [[ -z "$sb_state" ]]; then
        echo "Unknown"
    elif echo "$sb_state" | grep -qi "enabled"; then
        echo "Enabled"
    elif echo "$sb_state" | grep -qi "disabled"; then
        echo "Disabled"
    else
        echo "Unknown"
    fi
}

get_failure_reason() {
    local node="$1"
    local worker_pod
    worker_pod=$(get_worker_pod_for_node "$node")

    if [[ -z "$worker_pod" ]]; then
        get_module_failure_reason
        return
    fi

    local logs
    logs=$("${KUBE_CMD}" logs "$worker_pod" -n "$NAMESPACE" --tail=30 2>/dev/null || echo "")

    if echo "$logs" | grep -q "Module.*is in use"; then
        echo "Module in use"
    elif echo "$logs" | grep -q "Module.*not found"; then
        echo "Module not found"
    elif echo "$logs" | grep -q "FATAL"; then
        echo "Fatal error"
    elif echo "$logs" | grep -q "error\|Error"; then
        echo "Error in logs"
    else
        local pod_status
        pod_status=$("${KUBE_CMD}" get pod "$worker_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "$pod_status" == "Running" ]]; then
            echo "Pod running"
        elif [[ "$pod_status" == "Pending" ]]; then
            echo "Pod pending"
        else
            echo "-"
        fi
    fi
}

get_module_failure_reason() {
    local event_reason
    event_reason=$(get_recent_module_event_reason)

    if [[ -n "$event_reason" ]]; then
        echo "$event_reason"
    else
        echo "No loader pod"
    fi
}

get_recent_module_event_reason() {
    local events reason kind name message candidate=""

    events=$("${KUBE_CMD}" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' \
        -o jsonpath='{range .items[*]}{.reason}{"\t"}{.involvedObject.kind}{"\t"}{.involvedObject.name}{"\t"}{.message}{"\n"}{end}' 2>/dev/null || echo "")

    while IFS=$'\t' read -r reason kind name message; do
        if [[ "$name" != "$MODULE_NAME" && "$name" != "$MODULE_NAME-"* ]]; then
            continue
        fi

        case "$reason" in
            BuildimageFailed|BuildFailed)
                candidate="Build failed"
                ;;
            BuildStarted)
                candidate="Build running"
                ;;
            BuildimageCreated)
                candidate="Build queued"
                ;;
            Failed)
                if [[ "$message" == *"ErrImagePull"* ]] || [[ "$message" == *"Failed to pull image"* ]]; then
                    candidate="Image pull failed"
                fi
                ;;
            BackOff)
                if [[ "$message" == *"pulling image"* ]]; then
                    candidate="Image pull backoff"
                fi
                ;;
        esac
    done <<< "$events"

    echo "$candidate"
}

get_worker_pod_for_node() {
    local node="$1"
    local worker_pod

    worker_pod=$("${KUBE_CMD}" get pods -n "$NAMESPACE" \
        -l "kmm.node.kubernetes.io/module.name=$MODULE_NAME" \
        --field-selector "spec.nodeName=$node" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$worker_pod" ]]; then
        echo "$worker_pod"
        return
    fi

    worker_pod="kmm-worker-${node}-${MODULE_NAME}"
    if "${KUBE_CMD}" get pod "$worker_pod" -n "$NAMESPACE" &>/dev/null; then
        echo "$worker_pod"
    fi
}

# ============================================================================
# Compact Table Output (Default Mode)
# ============================================================================

print_compact_table() {
    print_header "VAST NFS Deployment Status"

    local selector
    selector=$("${KUBE_CMD}" get module "$MODULE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector}' 2>/dev/null)
    if [[ -z "$selector" ]] || [[ "$selector" == "{}" ]]; then
        echo "Module selector: {} (deploys to ALL nodes)"
    else
        echo "Module selector: $selector"
    fi
    echo ""

    local nodes
    if [[ -n "$NODE_FILTER" ]]; then
        if ! "${KUBE_CMD}" get node "$NODE_FILTER" &>/dev/null; then
            print_error "Node '$NODE_FILTER' not found"
            exit 1
        fi
        nodes="$NODE_FILTER"
        echo "Showing status for node: $NODE_FILTER"
        echo ""
    else
        nodes=$("${KUBE_CMD}" get nodes -o jsonpath='{.items[*].metadata.name}')
    fi

    echo -e "${CYAN}NODE                 STATUS       ROLE           OS              KERNEL                      KMM      VAST NFS            REASON${NC}"
    echo "-------------------  -----------  -------------  --------------  --------------------------  -------  ------------------  ----------------"
    local all_ok=true

    for node in $nodes; do
        local status role os_flavor kernel kmm_status vastnfs_version reason
        status=$(get_node_status "$node")
        role=$(get_node_role "$node")
        os_flavor=$(get_node_os "$node")
        kernel=$(get_node_kernel "$node")
        kmm_status=$(get_kmm_status "$node" "$role")
        vastnfs_version=$(check_node_vastnfs_status "$node")
        reason="-"

        local vastnfs_display="" vastnfs_color=""
        if [[ "$vastnfs_version" == "not_active" ]]; then
            vastnfs_display="Not installed"
            vastnfs_color="${RED}"
            if [[ "$kmm_status" == "Managed" ]]; then
                reason=$(get_failure_reason "$node")
                all_ok=false
            elif [[ "$kmm_status" == "Skipped" ]]; then
                reason="KMM skipped"
            elif [[ "$kmm_status" == "N/A" ]]; then
                reason="Control plane"
            fi
        else
            local short_version
            short_version=$(echo "$vastnfs_version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            if [[ -n "$short_version" ]]; then
                vastnfs_display="v$short_version"
            else
                vastnfs_display="Installed"
            fi
            vastnfs_color="${GREEN}"
        fi

        local status_color=""
        if [[ "$status" == "Ready" ]]; then
            status_color="${GREEN}"
        elif [[ "$status" == "Ready,Cord" ]]; then
            status_color="${YELLOW}"
        else
            status_color="${RED}"
        fi

        local kmm_color=""
        if [[ "$kmm_status" == "Managed" ]]; then
            kmm_color="${GREEN}"
        elif [[ "$kmm_status" == "Skipped" ]]; then
            kmm_color="${YELLOW}"
        fi

        printf "%-20s " "$node"
        echo -en "${status_color}"
        printf "%-11s" "$status"
        echo -en "${NC}  "
        printf "%-13s  " "$role"
        printf "%-14s  " "${os_flavor:0:14}"
        printf "%-26s  " "${kernel:0:26}"
        echo -en "${kmm_color}"
        printf "%-7s" "$kmm_status"
        echo -en "${NC}  "
        echo -en "${vastnfs_color}"
        printf "%-18s" "$vastnfs_display"
        echo -en "${NC}  "
        printf "%-16s\n" "$reason"
    done

    echo ""

    cleanup_debug_pods

    if [[ "$all_ok" == "true" ]]; then
        print_success "All KMM-managed nodes have VAST NFS installed"
    else
        print_warning "Some nodes do not have VAST NFS installed"
        echo ""
        echo "To see detailed logs, run: VERBOSE=true make verify"
        if [[ "${PLATFORM}" == "vanilla" ]]; then
            echo "To prepare a node:         make prepare-worker NODE=<node-name>"
        fi
    fi
}

# ============================================================================
# Verbose Output Functions (Original Detailed Mode)
# ============================================================================

check_module_status() {
    print_step "Checking KMM Module Status"

    if ! "${KUBE_CMD}" get module "$MODULE_NAME" -n "$NAMESPACE" &>/dev/null; then
        print_warning "Module '$MODULE_NAME' not found in namespace '$NAMESPACE'"
        print_info "This is expected after 'make build-only' (Module is deleted after builds complete)"
        print_info "Run 'make install' to deploy the Module to cluster nodes"
        return 0
    fi

    print_info "Module found: $MODULE_NAME"
    "${KUBE_CMD}" get module "$MODULE_NAME" -n "$NAMESPACE" -o wide

    local status
    status=$(get_module_status "$MODULE_NAME" "$NAMESPACE")
    if [[ -n "$status" ]]; then
        echo ""
        print_info "Module Status Details:"
        echo "$status" | jq '.' 2>/dev/null || echo "$status"
    fi

    return 0
}

check_kmm_node_selection() {
    print_step "Checking KMM Node Selection Status"

    local selector
    selector=$("${KUBE_CMD}" get module "$MODULE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector}' 2>/dev/null)

    if [[ -z "$selector" ]] || [[ "$selector" == "{}" ]]; then
        print_info "Module selector: {} (deploys to ALL nodes)"
    else
        print_info "Module selector: $selector"
    fi
    echo ""

    print_info "Node KMM labels:"
    echo ""
    printf "  %-25s %-15s %-15s\n" "NODE" "ENABLED" "KMM STATUS"
    printf "  %-25s %-15s %-15s\n" "----" "-------" "----------"

    local nodes
    nodes=$("${KUBE_CMD}" get nodes -o jsonpath='{.items[*].metadata.name}')
    for node in $nodes; do
        local enabled_label kmm_status=""
        enabled_label=$("${KUBE_CMD}" get node "$node" -o jsonpath='{.metadata.labels.vastnfs-kmm/enabled}' 2>/dev/null)

        if is_control_plane_only "$node"; then
            kmm_status="control-plane"
        elif [[ "${PLATFORM}" == "openshift" ]]; then
            kmm_status="KMM MANAGED"
        elif [[ "$enabled_label" == "true" ]]; then
            kmm_status="KMM MANAGED"
        else
            kmm_status="SKIPPED"
        fi

        printf "  %-25s %-15s %-15s\n" "$node" "${enabled_label:-<not set>}" "$kmm_status"
    done
    echo ""
}

show_worker_pod_logs() {
    local node="$1"

    local worker_pod
    worker_pod=$(get_worker_pod_for_node "$node")

    if [[ -z "$worker_pod" ]]; then
        print_info "  No worker pod found for node $node"
        return
    fi

    print_info "  Worker pod logs from $worker_pod:"
    echo ""
    local logs
    logs=$("${KUBE_CMD}" logs "$worker_pod" -n "$NAMESPACE" --tail=20 2>/dev/null || echo "")
    if [[ -n "$logs" ]]; then
        echo "$logs" | while IFS= read -r line; do
            if [[ "$line" == *"FATAL"* ]] || [[ "$line" == *"error"* ]] || [[ "$line" == *"Error"* ]]; then
                echo -e "    ${RED}$line${NC}"
            else
                echo "    $line"
            fi
        done
        echo ""
    else
        print_info "  No logs available"
    fi
}

check_vast_nfs_active() {
    print_step "Verifying VAST NFS is Active on Nodes"

    local nodes
    if [[ -n "$NODE_FILTER" ]]; then
        if ! "${KUBE_CMD}" get node "$NODE_FILTER" &>/dev/null; then
            print_error "Node '$NODE_FILTER' not found"
            return 1
        fi
        nodes="$NODE_FILTER"
        print_info "Checking single node: $NODE_FILTER"
    else
        nodes=$("${KUBE_CMD}" get nodes -o jsonpath='{.items[*].metadata.name}')
    fi

    local active_count=0
    local total_count=0
    local skipped_count=0
    local failed_nodes=()

    for node in $nodes; do
        if is_control_plane_only "$node"; then
            print_info "Skipping control-plane node: $node (not schedulable for workloads)"
            skipped_count=$((skipped_count + 1))
            continue
        fi

        total_count=$((total_count + 1))

        local kmm_status
        if [[ "${PLATFORM}" == "openshift" ]]; then
            kmm_status="[KMM: managed]"
        elif is_kmm_enabled "$node"; then
            kmm_status="[KMM: enabled]"
        else
            kmm_status="[KMM: skipped]"
        fi

        print_info "Checking node: $node $kmm_status"

        local version_check
        version_check=$(check_node_vastnfs_status "$node")

        if [[ "$version_check" == "not_active" ]]; then
            print_warning "  VAST NFS NOT ACTIVE - Using default kernel NFS"
            failed_nodes+=("$node")
            show_worker_pod_logs "$node"
        else
            print_success "  VAST NFS ACTIVE - $version_check"
            active_count=$((active_count + 1))
        fi
    done

    echo ""
    if [[ $skipped_count -gt 0 ]]; then
        print_info "Skipped: $skipped_count control-plane-only nodes"
    fi
    print_info "Summary: $active_count/$total_count worker nodes have VAST NFS active"

    if [[ $total_count -eq 0 ]]; then
        print_warning "No worker nodes found in the cluster"
        return 0
    elif [[ $active_count -eq 0 ]]; then
        print_error "VAST NFS is not active on any worker nodes"
        return 1
    elif [[ $active_count -lt $total_count ]]; then
        print_warning "VAST NFS is not active on all worker nodes"
        print_info "Failed nodes: ${failed_nodes[*]}"
        return 1
    else
        print_success "VAST NFS is active on all worker nodes"
        return 0
    fi
}

check_pods() {
    print_step "Checking Pods in Namespace"

    local pods
    pods=$("${KUBE_CMD}" get pods -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")

    if [[ -n "$pods" ]]; then
        print_info "Current pods:"
        "${KUBE_CMD}" get pods -n "$NAMESPACE"

        echo ""
        print_info "Recent events in namespace:"
        "${KUBE_CMD}" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -5 2>/dev/null || echo "No events found"
    fi
}

check_secure_boot() {
    print_step "Checking Secure Boot Status (if applicable)"

    local nodes node
    nodes=$("${KUBE_CMD}" get nodes -o jsonpath='{.items[0].metadata.name}')
    node=$(echo "$nodes" | awk '{print $1}')

    print_info "Checking secure boot status on node: $node"

    local signature
    if _use_oc_debug; then
        signature=$(_probe_signature_openshift "$node")
    else
        signature=$(_probe_signature_vanilla "$node")
    fi

    if [[ -n "$signature" ]]; then
        print_success "Module signature found:"
        echo "  $signature"
    else
        print_info "No module signature found (not using secure boot or unsigned modules)"
    fi

    local sb_state
    if _use_oc_debug; then
        sb_state=$(_probe_sb_state_openshift "$node")
    else
        sb_state=$(_probe_sb_state_vanilla "$node")
    fi

    if [[ "$sb_state" == "NOT_AVAILABLE" ]] || [[ -z "$sb_state" ]]; then
        print_info "Secure boot: mokutil not available (secure boot likely not enabled)"
    elif echo "$sb_state" | grep -qi "enabled"; then
        print_success "Secure boot: ENABLED"
    elif echo "$sb_state" | grep -qi "disabled"; then
        print_info "Secure boot: Disabled"
    else
        print_info "Secure boot status: $sb_state"
    fi
}

show_troubleshooting() {
    print_step "Troubleshooting Commands"
    echo ""
    echo "If VAST NFS is not working, try these commands:"
    echo ""
    echo "1. Check module logs:"
    echo "   ${KUBE_CMD} logs -l kmm.node.kubernetes.io/module.name=$MODULE_NAME -n $NAMESPACE"
    echo ""
    echo "2. Check KMM operator logs:"
    if [[ "${PLATFORM}" == "openshift" ]]; then
        echo "   ${KUBE_CMD} logs -n openshift-kmm deployment/kmm-operator-controller | grep -i $MODULE_NAME"
    else
        echo "   ${KUBE_CMD} logs -n kmm-operator-system deployment/kmm-operator-controller | grep -i $MODULE_NAME"
    fi
    echo ""
    echo "3. Restart module deployment:"
    echo "   ${KUBE_CMD} delete module $MODULE_NAME -n $NAMESPACE"
    echo "   # Then redeploy using make install or scripts"
    echo ""
    echo "4. Check node kernel version compatibility:"
    if _use_oc_debug; then
        echo "   ${KUBE_CMD} debug node/<node-name> -- chroot /host uname -r"
    else
        echo "   ${KUBE_CMD} debug node/<node-name> -it --image=busybox -- chroot /host uname -r"
    fi
    echo ""
    echo -e "${YELLOW}5. 'Module sunrpc is in use' error:${NC}"
    echo "   If you see 'FATAL: Module sunrpc is in use' in the logs, the in-tree NFS"
    echo "   modules are actively being used (e.g., by mounted NFS volumes)."
    echo ""
    if [[ "${PLATFORM}" == "vanilla" ]]; then
        echo "   To remediate, use the node preparation scripts which will:"
        echo "   - Cordon and drain the node"
        echo "   - Iteratively unload all NFS modules"
        echo "   - Allow KMM to load VAST NFS modules"
        echo ""
        echo "   For a single worker node:"
        echo "   make prepare-worker NODE=<node-name>"
        echo ""
        echo "   For all worker nodes (rolling update):"
        echo "   make prepare-workers"
    else
        echo "   Try: make graceful-unload  (cordons + unmounts + unloads NFS modules)"
    fi
    echo ""
}

cleanup_debug_pods() {
    # Clean up both the vanilla-style helper pods and OpenShift `oc debug`
    # ephemeral node-debugger pods.
    "${KUBE_CMD}" get pods -A --no-headers 2>/dev/null | grep -E "node-debugger|vastnfs-verify|sb-check|sb-state" | while read -r ns pod rest; do
        "${KUBE_CMD}" delete pod "$pod" -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
    done
}

# ============================================================================
# Main Execution
# ============================================================================

WAIT_TIMEOUT=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -m|--module)
            MODULE_NAME="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -w|--wait)
            WAIT_TIMEOUT="$2"
            shift 2
            ;;
        --node)
            NODE_FILTER="$2"
            shift 2
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

main_verbose() {
    print_header "VAST NFS Deployment Verification"

    check_verify_prerequisites
    check_cluster_connection

    show_configuration "Verification Configuration" "NAMESPACE" "MODULE_NAME" "PLATFORM"

    if [[ -n "$WAIT_TIMEOUT" ]]; then
        wait_for_module_ready "$MODULE_NAME" "$NAMESPACE" "$WAIT_TIMEOUT"
    fi

    local overall_status=0

    check_module_status || overall_status=1
    echo ""

    check_kmm_node_selection
    echo ""

    check_vast_nfs_active || overall_status=1
    echo ""

    check_pods
    echo ""

    echo ""

    check_secure_boot
    echo ""

    cleanup_debug_pods

    if [[ $overall_status -eq 0 ]]; then
        print_success "VAST NFS deployment verification PASSED"
        print_info "VAST NFS is properly deployed and active"
    else
        print_error "VAST NFS deployment verification FAILED"
        show_troubleshooting
        exit 1
    fi
}

main_compact() {
    check_verify_prerequisites
    check_cluster_connection 2>/dev/null || {
        print_error "Cannot connect to Kubernetes cluster"
        exit 1
    }

    print_compact_table
}

if [[ "$VERBOSE" == "true" ]]; then
    main_verbose
else
    main_compact
fi
