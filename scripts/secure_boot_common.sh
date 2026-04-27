#!/usr/bin/env bash

# Shared Secure Boot helpers for platform-aware node inspection and MOK state.
# This file should be sourced by scripts, not executed directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: this script should be sourced, not executed directly"
    exit 1
fi

SECURE_BOOT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${COMMON_SH_LOADED:-}" ]]; then
    # shellcheck source=common.sh
    source "${SECURE_BOOT_COMMON_DIR}/common.sh"
fi

sb_normalize_fingerprint() {
    tr '[:upper:]' '[:lower:]' | tr -d ':' | awk -F= '{print $NF}'
}

sb_cert_sha1() {
    local cert_file="$1"
    openssl x509 -inform der -in "$cert_file" -noout -fingerprint -sha1 | sb_normalize_fingerprint
}

sb_target_nodes() {
    local selector="${1:-}"

    if [[ -n "$selector" ]]; then
        "${KUBE_CMD}" get nodes -l "$selector" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true
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

sb_node_exec_script() {
    local node="$1"
    local script="$2"
    local script_b64

    script_b64=$(printf '%s' "$script" | base64 | tr -d '\n')

    if [[ "${PLATFORM}" == "openshift" && "${KUBE_CMD}" == "oc" ]]; then
        "${KUBE_CMD}" debug "node/${node}" -- chroot /host /bin/bash -lc \
            "printf '%s' '${script_b64}' | base64 -d | /bin/bash" 2>/dev/null
        return
    fi

    local pod_name
    pod_name="sb-${node//[^a-zA-Z0-9-]/-}-$$"
    "${KUBE_CMD}" run "$pod_name" -n "${NAMESPACE:-$DEFAULT_NAMESPACE}" --rm -i --restart=Never \
        --image="${HELPER_IMAGE:-busybox}" \
        --overrides='{
            "spec": {
                "nodeName": "'"$node"'",
                "hostPID": true,
                "containers": [{
                    "name": "secure-boot",
                    "image": "'"${HELPER_IMAGE:-busybox}"'",
                    "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "sh", "-lc", "printf %s '"${script_b64}"' | base64 -d | sh"],
                    "securityContext": {"privileged": true}
                }],
                "tolerations": [{"operator": "Exists"}]
            }
        }' 2>/dev/null
}

sb_node_exec() {
    local node="$1"
    shift
    local command="$*"

    sb_node_exec_script "$node" "$command"
}

sb_secure_boot_state() {
    local node="$1"

    sb_node_exec "$node" 'if command -v mokutil >/dev/null 2>&1; then mokutil --sb-state 2>/dev/null; else echo NOT_AVAILABLE; fi' \
        | awk '/SecureBoot|NOT_AVAILABLE/ {line=$0} END {if (line) print line}'
}

sb_is_secure_boot_enabled() {
    local node="$1"
    sb_secure_boot_state "$node" | grep -qi "enabled"
}

sb_mok_sha1_list() {
    local node="$1"
    local mokutil_arg="$2"

    sb_node_exec "$node" "if command -v mokutil >/dev/null 2>&1; then mokutil ${mokutil_arg} 2>/dev/null; else echo NOT_AVAILABLE; fi" \
        | awk -F': ' '/SHA1 Fingerprint/{print $2}' \
        | tr '[:upper:]' '[:lower:]' \
        | tr -d ':'
}

sb_node_has_cert_enrolled() {
    local node="$1"
    local expected_sha1="$2"

    sb_mok_sha1_list "$node" "--list-enrolled" | grep -qx "$expected_sha1"
}

sb_node_has_cert_pending() {
    local node="$1"
    local expected_sha1="$2"

    sb_mok_sha1_list "$node" "--list-new" | grep -qx "$expected_sha1"
}

sb_stage_mok_enrollment() {
    local node="$1"
    local cert_file="$2"
    local mok_password="$3"
    local timeout="${4:-60}"
    local cert_b64 password_b64

    cert_b64=$(base64 < "$cert_file" | tr -d '\n')
    password_b64=$(printf '%s' "$mok_password" | base64 | tr -d '\n')

    sb_node_exec_script "$node" "$(cat <<EOF
set -e
cert_path="/var/tmp/vastnfs_signing_key.der"
hash_path="/var/tmp/vastnfs_mok_hash"
umask 077
printf '%s' '${cert_b64}' | base64 -d > "\${cert_path}"
password=\$(printf '%s' '${password_b64}' | base64 -d)
mokutil --generate-hash="\${password}" > "\${hash_path}"
mokutil --import "\${cert_path}" --hash-file "\${hash_path}" || true
mokutil --timeout "${timeout}" || true
rm -f "\${hash_path}"
mokutil --list-new
EOF
)"
}
