#!/usr/bin/env bash

# Gracefully unload VAST NFS modules from cluster nodes.
#
# This should be run before 'make uninstall' to avoid stuck pods on upgrades.
#
# Options:
#   --force     Skip if modules are in use (for reinstall scenarios)
#   --check     Only check status, don't unload
#
# Platform-aware:
#   - On OpenShift (PLATFORM=openshift, oc available): uses `oc debug node/...`
#     to run the unload sequence in-place. This mirrors the long-standing
#     OpenShift behavior.
#   - Otherwise: uses a privileged `nsenter -t 1` pod with the unload script
#     injected as a ConfigMap.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---- Args ------------------------------------------------------------------
FORCE_MODE=false
CHECK_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE_MODE=true; shift ;;
        --check) CHECK_ONLY=true; shift ;;
        *)       shift ;;
    esac
done

print_header "VAST NFS Graceful Module Unload"

NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"

# Single place where we pick the platform flavor.
USE_OC_DEBUG=false
if [[ "${PLATFORM}" == "openshift" ]] && command -v oc >/dev/null 2>&1; then
    USE_OC_DEBUG=true
fi

if ! "${KUBE_CMD}" version --client >/dev/null 2>&1; then
    print_error "${KUBE_CMD} not found"
    exit 1
fi
check_cluster_connection

nodes=$("${KUBE_CMD}" get nodes -o jsonpath='{.items[*].metadata.name}')

if [ "$CHECK_ONLY" = true ]; then
    print_step "Checking VAST NFS module status on cluster nodes"
else
    print_step "Unloading VAST NFS modules from cluster nodes"
fi

# ---- Unload script body (runs on the node as root) ------------------------
# Note: $CHECK_ONLY and $FORCE_MODE are interpolated in by the caller below.
_build_unload_script() {
    local check_only="$1"
    local force_mode="$2"
    cat <<EOF
#!/bin/sh
echo "=== Checking VAST NFS status ==="

if [ ! -e /sys/module/sunrpc/parameters/nfs_bundle_version ] && \\
   [ ! -e /sys/module/sunrpc/parameters/nfs_bundle_git_version ]; then
    echo "STATUS: VAST NFS modules not loaded"
    echo "ACTION: none"
    exit 0
fi

if [ -e /sys/module/sunrpc/parameters/nfs_bundle_version ]; then
    echo "LOADED: \$(cat /sys/module/sunrpc/parameters/nfs_bundle_version)"
fi

echo ""
echo "=== Module Reference Counts ==="
modules_in_use=false
for mod in sunrpc rpcrdma compat_nfs_ssc lockd nfs_acl auth_rpcgss nfs nfsv3 nfsv4; do
    if [ -d /sys/module/\${mod} ]; then
        refcnt=\$(cat /sys/module/\${mod}/refcnt 2>/dev/null || echo "0")
        holders=\$(ls /sys/module/\${mod}/holders 2>/dev/null | tr "\\n" " " || echo "none")
        echo "  \${mod}: refcnt=\${refcnt} holders=[\${holders}]"
        if [ "\$refcnt" != "0" ]; then
            modules_in_use=true
        fi
    fi
done

echo ""
echo "=== Active NFS Mounts ==="
nfs_mounts=\$(grep -E "nfs4?[[:space:]]" /proc/mounts 2>/dev/null || true)
if [ -n "\$nfs_mounts" ]; then
    echo "\$nfs_mounts"
    echo "WARNING: NFS mounts are active - modules cannot be safely unloaded"
    modules_in_use=true
else
    echo "  No active NFS mounts"
fi

if [ "${check_only}" = "true" ]; then
    if [ "\$modules_in_use" = "true" ]; then
        echo ""
        echo "STATUS: Modules are in use"
        echo "ACTION: Cannot unload without stopping NFS workloads"
    else
        echo ""
        echo "STATUS: Modules can be unloaded"
        echo "ACTION: Run without --check to unload"
    fi
    exit 0
fi

if [ "\$modules_in_use" = "true" ] && [ "${force_mode}" != "true" ]; then
    echo ""
    echo "ERROR: Modules are in use. Cannot safely unload."
    echo "HINT: Either:"
    echo "  1. Stop all NFS workloads and unmount NFS filesystems, or"
    echo "  2. Use make reinstall instead (skips module unload), or"
    echo "  3. Run with --force to skip this node"
    echo ""
    echo "MODULES_IN_USE"
    exit 1
fi

echo ""
echo "=== Proceeding with graceful unload ==="

echo "Step 1: Unmounting NFS filesystems..."
umount -a -t nfs4 2>/dev/null || true
umount -a -t nfs  2>/dev/null || true

echo "Step 2: Stopping RPC services..."
systemctl stop rpc-gssd        2>/dev/null || true
systemctl stop nfs-client.target 2>/dev/null || true
if ! systemctl is-active rpcbind.socket >/dev/null 2>&1; then
    systemctl stop rpcbind 2>/dev/null || true
fi

echo "Step 3: Unmounting rpc_pipefs..."
for path in /var/lib/nfs/rpc_pipefs /run/rpc_pipefs; do
    if grep -q "\${path} rpc_pipefs" /proc/mounts 2>/dev/null; then
        umount \${path} 2>/dev/null || true
    fi
done

echo "Step 4: Dropping caches..."
sync
echo 3 > /proc/sys/vm/drop_caches
sleep 2

echo "Step 5: Unloading NFS kernel modules..."
for mod in nfsv4 nfsv3 nfs nfsd rpcsec_gss_krb5 auth_rpcgss nfs_acl lockd nfs_ssc compat_nfs_ssc rpcrdma sunrpc; do
    if [ -d /sys/module/\${mod} ]; then
        echo "  Unloading \${mod}..."
        for attempt in 1 2 3; do
            if rmmod \${mod} 2>/dev/null; then
                echo "    OK"
                break
            else
                if [ \$attempt -lt 3 ]; then
                    echo "    Retry \$attempt..."
                    sleep 1
                else
                    echo "    FAILED (module may be in use)"
                fi
            fi
        done
    fi
done

echo ""
echo "=== Final State ==="
if [ -e /sys/module/sunrpc/parameters/nfs_bundle_version ]; then
    echo "WARNING: sunrpc still loaded - some modules could not be unloaded"
    echo "HINT: Use make reinstall to reinstall without unloading"
else
    echo "SUCCESS: All VAST NFS modules unloaded"
fi
EOF
}

# ---- Run script on a node (platform-aware) --------------------------------
_run_on_node_openshift() {
    local node="$1" script_body="$2"
    # Pipe the script body as bash stdin via chroot.
    oc debug "node/${node}" -- chroot /host bash -s <<< "${script_body}" 2>&1 | sed 's/^/  /'
}

_run_on_node_vanilla() {
    local node="$1" script_body="$2"
    local pod_name="graceful-unload-${node//[^a-z0-9-]/-}-$$"
    local cm_name="unload-script-${node//[^a-z0-9-]/-}-$$"

    "${KUBE_CMD}" create configmap "$cm_name" -n "$NAMESPACE" \
        --from-literal=unload.sh="$script_body" \
        -o yaml --dry-run=client \
        | "${KUBE_CMD}" apply -f - >/dev/null 2>&1

    "${KUBE_CMD}" apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
  namespace: $NAMESPACE
spec:
  nodeName: $node
  hostPID: true
  restartPolicy: Never
  tolerations:
  - operator: Exists
  volumes:
  - name: script
    configMap:
      name: $cm_name
      defaultMode: 0755
  - name: host-tmp
    hostPath:
      path: /tmp
      type: Directory
  containers:
  - name: unload
    image: alpine
    securityContext:
      privileged: true
    volumeMounts:
    - name: script
      mountPath: /scripts
    - name: host-tmp
      mountPath: /host-tmp
    command:
    - /bin/sh
    - -c
    - |
      cp /scripts/unload.sh /host-tmp/unload-\$\$.sh
      chmod +x /host-tmp/unload-\$\$.sh
      nsenter -t 1 -m -u -i -n -- /bin/sh /tmp/unload-\$\$.sh
      EXIT_CODE=\$?
      rm -f /host-tmp/unload-\$\$.sh
      exit \$EXIT_CODE
EOF

    # Wait for completion
    local i
    for i in $(seq 1 60); do
        local phase
        phase=$("${KUBE_CMD}" get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] || [ "$phase" = "NotFound" ]; then
            break
        fi
        sleep 1
    done

    # Grab logs
    if "${KUBE_CMD}" get pod "$pod_name" -n "$NAMESPACE" >/dev/null 2>&1; then
        "${KUBE_CMD}" logs "$pod_name" -n "$NAMESPACE" 2>/dev/null | sed 's/^/  /'
    fi

    "${KUBE_CMD}" delete pod       "$pod_name" -n "$NAMESPACE" --force --grace-period=0 >/dev/null 2>&1 || true
    "${KUBE_CMD}" delete configmap "$cm_name"  -n "$NAMESPACE"                             >/dev/null 2>&1 || true
}

# ---- Main loop ------------------------------------------------------------
modules_in_use=false
UNLOAD_SCRIPT="$(_build_unload_script "$CHECK_ONLY" "$FORCE_MODE")"

for node in $nodes; do
    print_info "Processing node: $node"

    if [ "${USE_OC_DEBUG}" = "true" ]; then
        result=$(_run_on_node_openshift "$node" "$UNLOAD_SCRIPT")
    else
        result=$(_run_on_node_vanilla "$node" "$UNLOAD_SCRIPT")
    fi

    echo "$result"

    if echo "$result" | grep -q "MODULES_IN_USE"; then
        modules_in_use=true
        print_warning "Modules in use on node: $node"
    elif echo "$result" | grep -q "SUCCESS"; then
        print_success "Successfully unloaded modules from node: $node"
    else
        print_info "Completed processing node: $node"
    fi
    echo ""
done

if [ "$modules_in_use" = true ] && [ "$FORCE_MODE" != "true" ]; then
    echo ""
    print_warning "Some nodes have modules in use"
    print_info "Options:"
    print_info "  1. Stop NFS workloads on affected nodes and retry"
    print_info "  2. Use 'make reinstall' instead (safe for already-loaded modules)"
    print_info "  3. Run './scripts/graceful_unload.sh --force' to skip affected nodes"
    exit 1
fi

print_success "Graceful unload complete"
print_info "You can now run 'make uninstall' safely"
