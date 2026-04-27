#!/usr/bin/env bash

# Remove host-side VAST NFS driver artifacts from all cluster nodes.
#
# This is intended to run after graceful_unload.sh has unloaded any active
# VAST NFS modules. It removes only VAST-owned staging files and module files
# under /lib/modules/*/extra, then refreshes module dependency metadata.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
HELPER_IMAGE="${VASTNFS_HELPER_IMAGE:-${HELPER_IMAGE:-alpine:latest}}"

if [[ "${PLATFORM}" == "openshift" ]] && command -v oc >/dev/null 2>&1; then
    USE_OC_DEBUG=true
else
    USE_OC_DEBUG=false
fi

_build_cleanup_script() {
    cat <<'NODE_CLEANUP'
#!/bin/sh
set -u

changed_kernels=""

remember_kernel() {
    kernel="$1"
    case " $changed_kernels " in
        *" $kernel "*) ;;
        *) changed_kernels="$changed_kernels $kernel" ;;
    esac
}

remove_path() {
    path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        echo "Removing $path"
        rm -rf "$path"
    fi
}

echo "=== Runtime status ==="
if [ -e /sys/module/sunrpc/parameters/nfs_bundle_version ]; then
    echo "WARNING: VAST NFS still appears loaded:"
    cat /sys/module/sunrpc/parameters/nfs_bundle_version 2>/dev/null || true
    echo "Run make graceful-unload and retry cleanup if files cannot be removed."
else
    echo "VAST NFS is not loaded"
fi

echo ""
echo "=== Removing VAST NFS host artifacts ==="
remove_path /usr/local/bin/vastnfs-ctl
remove_path /tmp/vastnfs-opt
remove_path /tmp/vastnfs-ctl
rm -f /tmp/vastnfs-*.sh 2>/dev/null || true

echo ""
echo "=== Removing VAST NFS module files from /lib/modules/*/extra ==="
for kdir in /lib/modules/*; do
    [ -d "$kdir" ] || continue
    kernel="$(basename "$kdir")"

    if [ -d "$kdir/extra/vastnfs" ]; then
        remove_path "$kdir/extra/vastnfs"
        remember_kernel "$kernel"
    fi

    if [ -d "$kdir/extra" ]; then
        find "$kdir/extra" -type f -name '*.ko*' 2>/dev/null | while IFS= read -r module_file; do
            if modinfo "$module_file" 2>/dev/null | grep -qi 'vast'; then
                echo "Removing $module_file"
                rm -f "$module_file"
                echo "$kernel" >> /tmp/vastnfs-cleanup-kernels.$$
            fi
        done
    fi
done

if [ -f /tmp/vastnfs-cleanup-kernels.$$ ]; then
    while IFS= read -r kernel; do
        remember_kernel "$kernel"
    done < /tmp/vastnfs-cleanup-kernels.$$
    rm -f /tmp/vastnfs-cleanup-kernels.$$
fi

echo ""
echo "=== Refreshing module dependency metadata ==="
for kernel in $changed_kernels; do
    if command -v depmod >/dev/null 2>&1; then
        echo "Running depmod for $kernel"
        depmod "$kernel" 2>/dev/null || true
    fi
done

echo ""
echo "=== Restoring service masks touched by legacy fallback installs ==="
if command -v systemctl >/dev/null 2>&1; then
    systemctl unmask rpcbind.socket rpcbind rpc-statd nfs-client.target nfs-common 2>/dev/null || true
fi

echo ""
echo "Node cleanup complete"
NODE_CLEANUP
}

_run_on_node_openshift() {
    local node="$1" script_body="$2"
    oc debug "node/${node}" -- chroot /host bash -c "${script_body}" 2>&1 | sed 's/^/  /'
}

_run_on_node_vanilla() {
    local node="$1" script_body="$2"
    local pod_name="vastnfs-cleanup-${node//[^a-z0-9-]/-}-$$"
    local cm_name="vastnfs-cleanup-${node//[^a-z0-9-]/-}-$$"

    "${KUBE_CMD}" create configmap "$cm_name" -n "$NAMESPACE" \
        --from-literal=cleanup.sh="$script_body" \
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
  - name: cleanup
    image: $HELPER_IMAGE
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
      cp /scripts/cleanup.sh /host-tmp/vastnfs-cleanup-\$\$.sh
      chmod +x /host-tmp/vastnfs-cleanup-\$\$.sh
      nsenter -t 1 -m -u -i -n -- /bin/sh /tmp/vastnfs-cleanup-\$\$.sh
      EXIT_CODE=\$?
      rm -f /host-tmp/vastnfs-cleanup-\$\$.sh
      exit \$EXIT_CODE
EOF

    local i phase
    for i in $(seq 1 90); do
        phase=$("${KUBE_CMD}" get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] || [ "$phase" = "NotFound" ]; then
            break
        fi
        sleep 1
    done

    if "${KUBE_CMD}" get pod "$pod_name" -n "$NAMESPACE" >/dev/null 2>&1; then
        "${KUBE_CMD}" logs "$pod_name" -n "$NAMESPACE" 2>/dev/null | sed 's/^/  /'
    fi

    "${KUBE_CMD}" delete pod "$pod_name" -n "$NAMESPACE" --force --grace-period=0 >/dev/null 2>&1 || true
    "${KUBE_CMD}" delete configmap "$cm_name" -n "$NAMESPACE" >/dev/null 2>&1 || true
}

main() {
    print_header "VAST NFS Node Driver Cleanup"
    check_cluster_connection

    local nodes cleanup_script node result
    nodes=$("${KUBE_CMD}" get nodes -o jsonpath='{.items[*].metadata.name}')
    cleanup_script="$(_build_cleanup_script)"

    for node in $nodes; do
        print_info "Cleaning node: $node"
        if [ "$USE_OC_DEBUG" = true ]; then
            result=$(_run_on_node_openshift "$node" "$cleanup_script")
        else
            result=$(_run_on_node_vanilla "$node" "$cleanup_script")
        fi
        echo "$result"
        echo ""
    done

    print_success "Node driver cleanup complete"
}

main "$@"
