#!/usr/bin/env bash

# Fail normal installs when target nodes require signed kernel modules.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
NODE_SELECTOR="${NODE_SELECTOR:-}"
ALLOW_UNSIGNED_ON_SECURE_BOOT="${ALLOW_UNSIGNED_ON_SECURE_BOOT:-false}"

usage() {
    echo "Usage: $0"
    echo ""
    echo "Checks whether target nodes have Secure Boot enabled."
    echo ""
    echo "Environment:"
    echo "  PLATFORM                         openshift | vanilla"
    echo "  KUBE_CMD                         oc | kubectl"
    echo "  NODE_SELECTOR                    Optional key=value selector"
    echo "  ALLOW_UNSIGNED_ON_SECURE_BOOT    true to bypass the guard"
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "$ALLOW_UNSIGNED_ON_SECURE_BOOT" == "true" ]]; then
    print_warning "Skipping Secure Boot guard because ALLOW_UNSIGNED_ON_SECURE_BOOT=true"
    exit 0
fi

get_target_nodes() {
    if [[ -n "$NODE_SELECTOR" ]]; then
        "${KUBE_CMD}" get nodes -l "$NODE_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true
        return
    fi

    local worker_nodes
    worker_nodes=$("${KUBE_CMD}" get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [[ -n "$worker_nodes" ]]; then
        echo "$worker_nodes"
    else
        "${KUBE_CMD}" get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true
    fi
}

check_node_secure_boot() {
    local node="$1"
    local state=""

    if [[ "$PLATFORM" == "openshift" ]] && [[ "$KUBE_CMD" == "oc" ]]; then
        state=$(oc debug "node/${node}" -- chroot /host bash -c \
            'if command -v mokutil >/dev/null 2>&1; then mokutil --sb-state 2>/dev/null; else echo NOT_AVAILABLE; fi' \
            2>/dev/null | awk '/SecureBoot|NOT_AVAILABLE/ {print; exit}' || true)
    else
        local pod_name="sb-guard-${node//[^a-z0-9-]/-}-$$"
        state=$("${KUBE_CMD}" run "$pod_name" -n "$NAMESPACE" --rm -i --restart=Never \
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
            }' 2>/dev/null | awk '/SecureBoot|NOT_AVAILABLE/ {print; exit}' || true)
    fi

    if echo "$state" | grep -qi "enabled"; then
        echo "$node"
    fi
}

main() {
    print_step "Checking whether Secure Boot signing is required..."

    local nodes
    nodes=$(get_target_nodes)
    if [[ -z "$nodes" ]]; then
        print_warning "No target nodes found for Secure Boot check; continuing"
        return 0
    fi

    local secure_boot_nodes=()
    local node
    for node in $nodes; do
        if [[ -n "$(check_node_secure_boot "$node")" ]]; then
            secure_boot_nodes+=("$node")
        fi
    done

    if [[ ${#secure_boot_nodes[@]} -gt 0 ]]; then
        print_error "Secure Boot is enabled on target node(s): ${secure_boot_nodes[*]}"
        print_error "Unsigned VAST NFS modules will be rejected by the kernel."
        print_info "Use: make install-secure-boot VASTNFS_VERSION=${VASTNFS_VERSION:-<version>}"
        print_info "Or use existing keys: make install-secure-boot-with-keys PRIVATE_KEY_FILE=<key> PUBLIC_CERT_FILE=<cert> VASTNFS_VERSION=${VASTNFS_VERSION:-<version>}"
        print_info "To bypass intentionally: ALLOW_UNSIGNED_ON_SECURE_BOOT=true make install ..."
        return 1
    fi

    print_info "Secure Boot is not enabled on target nodes; normal install can continue"
}

main "$@"
