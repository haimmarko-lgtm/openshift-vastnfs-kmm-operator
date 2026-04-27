#!/usr/bin/env bash

# Fail normal installs when target nodes require signed kernel modules.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=secure_boot_common.sh
source "${SCRIPT_DIR}/secure_boot_common.sh"

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

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "$ALLOW_UNSIGNED_ON_SECURE_BOOT" == "true" ]]; then
    print_warning "Skipping Secure Boot guard because ALLOW_UNSIGNED_ON_SECURE_BOOT=true"
    exit 0
fi

main() {
    print_step "Checking whether Secure Boot signing is required..."

    local nodes
    nodes=$(sb_target_nodes "$NODE_SELECTOR")
    if [[ -z "$nodes" ]]; then
        print_warning "No target nodes found for Secure Boot check; continuing"
        return 0
    fi

    local secure_boot_nodes=()
    local node
    for node in $nodes; do
        if sb_is_secure_boot_enabled "$node"; then
            secure_boot_nodes+=("$node")
        fi
    done

    if [[ ${#secure_boot_nodes[@]} -gt 0 ]]; then
        print_error "Secure Boot is enabled on target node(s): ${secure_boot_nodes[*]}"
        print_error "Unsigned VAST NFS modules will be rejected by the kernel."
        print_info "Use the signed flow:"
        print_info "  make install-secure-boot VASTNFS_VERSION=${VASTNFS_VERSION:-<version>}"
        print_info "To use existing signing material, pass PRIVATE_KEY_FILE and PUBLIC_CERT_FILE to the same target."
        print_info "To bypass intentionally: ALLOW_UNSIGNED_ON_SECURE_BOOT=true make install ..."
        return 1
    fi

    print_info "Secure Boot is not enabled on target nodes; normal install can continue"
}

main "$@"
