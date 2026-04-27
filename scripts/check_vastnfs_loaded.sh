#!/usr/bin/env bash
# Check if VAST NFS is currently loaded on any cluster node.
#
# Exit codes:
#   0 - VAST NFS is loaded on at least one node
#   1 - VAST NFS is not loaded on any node, or no nodes found
#
# Platform-aware:
#   - On OpenShift (PLATFORM=openshift, oc available): uses `oc debug node/...`
#   - Otherwise: uses `kubectl run --rm` with a host-path mounted busybox pod
#
# Environment:
#   PLATFORM  - openshift | vanilla (default: auto-detected)
#   KUBE_CMD  - kubectl | oc (default: platform-based)
#   NAMESPACE - namespace used for helper pods (default: default)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Platform detection (cheap and safe in $(shell ...) contexts).
if [[ -z "${PLATFORM:-}" ]] && [[ -x "${HERE}/detect_platform.sh" ]]; then
    PLATFORM="$(${HERE}/detect_platform.sh)"
fi
PLATFORM="${PLATFORM:-vanilla}"

# Pick a CLI
if [[ -z "${KUBE_CMD:-}" ]]; then
    if [[ "${PLATFORM}" == "openshift" ]] && command -v oc >/dev/null 2>&1; then
        KUBE_CMD="oc"
    elif command -v kubectl >/dev/null 2>&1; then
        KUBE_CMD="kubectl"
    elif command -v oc >/dev/null 2>&1; then
        KUBE_CMD="oc"
    else
        exit 1
    fi
fi

NAMESPACE="${NAMESPACE:-default}"

nodes=$("${KUBE_CMD}" get nodes --request-timeout=5s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
if [ -z "$nodes" ]; then
    exit 1
fi

_check_openshift_node() {
    local node="$1"
    "${KUBE_CMD}" debug "node/${node}" -- chroot /host bash -c '
        if [[ -e /sys/module/sunrpc/parameters/nfs_bundle_version ]] || \
           [[ -e /sys/module/sunrpc/parameters/nfs_bundle_git_version ]]; then
            echo "VASTNFS_LOADED"
        else
            echo "VASTNFS_NOT_LOADED"
        fi
    ' 2>&1 | grep "VASTNFS_" | head -1
}

_check_vanilla_node() {
    local node="$1"
    local pod_name="chk-vastnfs-${node//[^a-z0-9-]/-}-$$"
    "${KUBE_CMD}" run "$pod_name" -n "$NAMESPACE" --rm -i --restart=Never \
        --image=busybox \
        --overrides='{
            "spec": {
                "nodeName": "'"$node"'",
                "containers": [{
                    "name": "check",
                    "image": "busybox",
                    "command": ["sh", "-c", "if [ -e /host-sys/module/sunrpc/parameters/nfs_bundle_version ] || [ -e /host-sys/module/sunrpc/parameters/nfs_bundle_git_version ]; then echo VASTNFS_LOADED; else echo VASTNFS_NOT_LOADED; fi"],
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
        }' 2>/dev/null | grep "VASTNFS_" | head -1
}

for node in $nodes; do
    if [[ "${PLATFORM}" == "openshift" ]] && [[ "${KUBE_CMD}" == "oc" ]]; then
        result=$(_check_openshift_node "$node")
    else
        result=$(_check_vanilla_node "$node")
    fi

    if [[ "$result" == "VASTNFS_LOADED" ]]; then
        exit 0
    fi
done

exit 1
