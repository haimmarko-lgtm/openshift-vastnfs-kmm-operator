#!/bin/bash

# VAST NFS Node Preparation Script for Production Rolling Updates
# 
# This script prepares a node for VAST NFS deployment by:
# 1. Cordoning the node
# 2. Draining all pods (except DaemonSets)
# 3. Getting kernel version and validating environment
# 4. Copying VAST NFS modules and vastnfs-ctl to node
# 5. Using vastnfs-ctl reload (primary method) or manual fallback
# 6. Verifying VAST NFS is loaded
# 7. Uncordoning the node
#
# Primary method: vastnfs-ctl reload (handles unload + reload automatically)
# Fallback: Manual service stop, process kill, module unload, then load
#
# Works with any Linux distribution (Ubuntu, RHEL, CentOS, Rocky, SUSE, immutable OS, etc.)
# NO REBOOT required - uses vastnfs-ctl reload or iterative approach
#
# Usage: ./prepare_node_for_vastnfs.sh <node-name> [--max-attempts N] [--helper-image IMAGE]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

# Keep the existing command style while honoring PLATFORM/KUBE_CMD.
kubectl() {
    if [[ "${KUBE_CMD}" == "oc" ]]; then
        case "$1" in
            cordon|drain|uncordon)
                local adm_cmd="$1"
                shift
                command oc adm "$adm_cmd" "$@"
                return
                ;;
        esac
    fi
    command "${KUBE_CMD}" "$@"
}

resolve_image_reference() {
    local image="$1"

    if [[ "${PLATFORM}" != "openshift" ]] || [[ "${KUBE_CMD}" != "oc" ]]; then
        echo "$image"
        return
    fi

    # OpenShift nodes can occasionally fail tag lookup against the internal
    # registry while digest pulls work. Resolve ImageStreamTags to immutable
    # digest references before creating helper pods.
    local image_without_tag tag stream resolved
    image_without_tag="${image%:*}"
    tag="${image##*:}"
    stream="${image_without_tag##*/}"

    if [[ -z "$tag" ]] || [[ "$tag" == "$image" ]] || [[ -z "$stream" ]]; then
        echo "$image"
        return
    fi

    resolved=$(command oc get istag "${stream}:${tag}" -n "$NAMESPACE" \
        -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)

    if [[ -n "$resolved" ]]; then
        echo "$resolved"
    else
        echo "$image"
    fi
}

select_vastnfs_image() {
    local base_image="$1"

    if [[ "${PLATFORM}" == "openshift" ]] && [[ "${KUBE_CMD}" == "oc" ]]; then
        local secure_boot_image="${base_image}-secureboot"
        local resolved_secure_boot_image
        resolved_secure_boot_image=$(resolve_image_reference "$secure_boot_image")

        if [[ "$resolved_secure_boot_image" != "$secure_boot_image" ]]; then
            echo "$secure_boot_image"
            return
        fi
    fi

    echo "$base_image"
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() { echo -e "${GREEN}[STEP]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

usage() {
    echo "Usage: $0 <node-name> [OPTIONS]"
    echo ""
    echo "Prepares a Kubernetes node for VAST NFS deployment."
    echo "Works with any Linux distribution - NO REBOOT required."
    echo ""
    echo "Options:"
    echo "  --max-attempts N      Maximum unload attempts for fallback method (default: 60)"
    echo "  --helper-image IMAGE  Container image for helper pods (default: alpine:latest)"
    echo "  --no-kubelet-stop     Don't stop kubelet even if module unload fails (fallback only)"
    echo "  --unload-only         Only unload modules, don't load VAST NFS (let KMM handle it)"
    echo ""
    echo "Required environment variables (not needed with --unload-only):"
    echo "  VASTNFS_VERSION       VAST NFS version (e.g., 4.5.5)"
    echo "  KMM_IMG_REPO          Image repository for VAST NFS modules"
    echo ""
    echo "Optional environment variables:"
    echo "  VASTNFS_HELPER_IMAGE  Override default helper image"
    echo ""
    echo "The script will:"
    echo "  1. Cordon the node"
    echo "  2. Drain all pods (except DaemonSets)"
    echo "  3. Copy VAST NFS modules and vastnfs-ctl from KMM image"
    echo "  4. Run vastnfs-ctl reload (primary method)"
    echo "     - If vastnfs-ctl reload fails, use manual fallback"
    echo "  5. Verify VAST NFS is loaded"
    echo "  6. Uncordon the node"
    echo ""
    echo "Note: The fallback method uses iterative module unloading. At halfway point,"
    echo "      it will temporarily stop kubelet to release NFS references if needed."
    echo ""
    exit 1
}

if [ -z "$1" ] || [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    usage
fi

NODE_NAME="$1"
MAX_ATTEMPTS=60
HELPER_IMAGE="${VASTNFS_HELPER_IMAGE:-alpine:latest}"
NAMESPACE="${NAMESPACE:-vastnfs-kmm}"
if [[ -z "${PREPARE_SERVICE_ACCOUNT:-}" ]]; then
    if [[ "${PLATFORM}" == "openshift" ]]; then
        PREPARE_SERVICE_ACCOUNT="vastnfs-kmm-sa"
    else
        PREPARE_SERVICE_ACCOUNT="default"
    fi
fi
ALLOW_KUBELET_STOP=1
UNLOAD_ONLY=0
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --max-attempts)
            MAX_ATTEMPTS="$2"
            shift 2
            ;;
        --helper-image)
            HELPER_IMAGE="$2"
            shift 2
            ;;
        --no-kubelet-stop)
            ALLOW_KUBELET_STOP=0
            shift
            ;;
        --unload-only)
            UNLOAD_ONLY=1
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Verify node exists
if ! kubectl get node "$NODE_NAME" &>/dev/null; then
    print_error "Node '$NODE_NAME' not found"
    exit 1
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    print_error "Namespace '$NAMESPACE' does not exist"
    print_info "Run 'make install VASTNFS_VERSION=${VASTNFS_VERSION:-<version>}' first to recreate KMM resources and push the module image."
    exit 1
fi

if [[ "$PREPARE_SERVICE_ACCOUNT" != "default" ]] && ! kubectl get serviceaccount "$PREPARE_SERVICE_ACCOUNT" -n "$NAMESPACE" >/dev/null 2>&1; then
    print_error "ServiceAccount '$PREPARE_SERVICE_ACCOUNT' does not exist in namespace '$NAMESPACE'"
    print_info "Run 'make install VASTNFS_VERSION=${VASTNFS_VERSION:-<version>}' first to recreate the OpenShift privileged service account."
    exit 1
fi

if [ "$UNLOAD_ONLY" != "1" ] && [ -n "${VASTNFS_VERSION:-}" ] && [ -n "${KMM_IMG_REPO:-}" ]; then
    PRECHECK_KERNEL_VERSION=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null || echo "")
    PRECHECK_IMAGE=$(select_vastnfs_image "${KMM_IMG_REPO}:${PRECHECK_KERNEL_VERSION}-vastnfs-${VASTNFS_VERSION}")
    PRECHECK_RESOLVED_IMAGE=$(resolve_image_reference "$PRECHECK_IMAGE")

    if [[ "${PLATFORM}" == "openshift" ]] && [[ "${KUBE_CMD}" == "oc" ]] && [[ "$PRECHECK_RESOLVED_IMAGE" == "$PRECHECK_IMAGE" ]]; then
        print_error "VAST NFS image tag is not available in the OpenShift ImageStream:"
        print_error "  $PRECHECK_IMAGE"
        print_info "Run 'make install VASTNFS_VERSION=$VASTNFS_VERSION' and wait for the build/push to complete before preparing nodes."
        exit 1
    fi
fi

print_step "=========================================="
print_step "Preparing node: $NODE_NAME"
print_step "Kube CLI: $KUBE_CMD"
print_step "Max unload attempts: $MAX_ATTEMPTS"
print_step "Helper image: $HELPER_IMAGE"
if [ "$ALLOW_KUBELET_STOP" = "1" ]; then
    print_step "Kubelet stop fallback: ENABLED (at attempt $((MAX_ATTEMPTS / 2)))"
else
    print_step "Kubelet stop fallback: DISABLED"
fi
print_step "=========================================="

# Step 1: Cordon the node
print_step "Step 1: Cordoning node..."
kubectl cordon "$NODE_NAME"
print_success "Node cordoned"

# Step 2: Drain the node
print_step "Step 2: Draining node (evicting all pods)..."
if kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s 2>&1; then
    print_success "Node drained successfully"
else
    print_warning "Drain completed with warnings (continuing...)"
fi

# Step 2b: Delete DaemonSet pods that may use NFS (they will restart after uncordon)
print_step "Step 2b: Removing DaemonSet pods that may use NFS..."
# Find and delete CSI driver pods and other NFS-using DaemonSets on this node
for ns in vast-csi vast-csi-block default kube-system; do
    DAEMONSET_PODS=$(kubectl get pods -n "$ns" --field-selector spec.nodeName="$NODE_NAME" -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="DaemonSet")]}{.metadata.name}{" "}{end}' 2>/dev/null || echo "")
    for pod in $DAEMONSET_PODS; do
        # Check if pod might use NFS by looking at volume types
        if kubectl get pod "$pod" -n "$ns" -o yaml 2>/dev/null | grep -qE "(nfs:|csi.*vast)"; then
            print_info "Deleting NFS-using DaemonSet pod: $ns/$pod"
            kubectl delete pod "$pod" -n "$ns" --force --grace-period=0 2>/dev/null || true
        fi
    done
done
# Also delete any CSI node pods explicitly
kubectl delete pods -n vast-csi -l app=csi-vast-node --field-selector spec.nodeName="$NODE_NAME" --force --grace-period=0 2>/dev/null || true
kubectl delete pods -n vast-csi-block -l app=block-vast-node --field-selector spec.nodeName="$NODE_NAME" --force --grace-period=0 2>/dev/null || true
sleep 3
print_success "DaemonSet pods removed"

# Handle --unload-only mode
if [ "$UNLOAD_ONLY" = "1" ]; then
    print_step "Step 3: Unloading NFS modules (--unload-only mode)..."
    print_info "Will only unload modules, KMM will handle loading after uncordon"
    
    # Run unload-only script
    UNLOAD_ONLY_SCRIPT='#!/bin/sh
MAX_ATTEMPTS='"$MAX_ATTEMPTS"'
ALLOW_KUBELET_STOP='"$ALLOW_KUBELET_STOP"'
SLEEP_BETWEEN=3
KUBELET_STOPPED=0

echo "=== Host OS Information ==="
cat /etc/os-release 2>/dev/null | head -5 || echo "Unknown OS"
echo "Kernel: $(uname -r)"
echo ""

# Function to stop all NFS/RPC services
stop_nfs_services() {
    echo "=== Stopping and masking NFS/RPC services ==="
    if command -v systemctl >/dev/null 2>&1; then
        echo "Using systemd..."
        for svc in nfs-server nfsdcld nfs-mountd nfs-idmapd rpc-gssd nfs-blkmap \
                   nfs-client.target rpc-statd rpcbind.socket rpcbind; do
            systemctl stop "$svc" 2>/dev/null && echo "  Stopped: $svc" || true
        done
        for svc in rpcbind.socket rpcbind rpc-statd nfs-client.target; do
            systemctl disable "$svc" 2>/dev/null || true
            systemctl mask "$svc" 2>/dev/null && echo "  Masked: $svc" || true
        done
    fi
    if command -v service >/dev/null 2>&1; then
        echo "Trying SysV init services..."
        for svc in rpcbind nfs nfs-kernel-server nfs-common portmap; do
            service "$svc" stop 2>/dev/null && echo "  Stopped: $svc" || true
        done
    fi
}

kill_rpc_processes() {
    echo ""
    echo "=== Killing any remaining RPC processes ==="
    if command -v pkill >/dev/null 2>&1; then
        pkill -9 rpcbind 2>/dev/null && echo "  Killed: rpcbind" || true
        pkill -9 rpc.statd 2>/dev/null && echo "  Killed: rpc.statd" || true
        pkill -9 rpc.mountd 2>/dev/null && echo "  Killed: rpc.mountd" || true
        pkill -9 rpc.idmapd 2>/dev/null && echo "  Killed: rpc.idmapd" || true
        pkill -9 rpc.gssd 2>/dev/null && echo "  Killed: rpc.gssd" || true
        pkill -9 nfsd 2>/dev/null && echo "  Killed: nfsd" || true
    fi
    sleep 1
}

unmount_nfs_filesystems() {
    echo ""
    echo "=== Unmounting NFS/RPC filesystems ==="
    mount | grep " type nfs" | awk "{print \$3}" | while read mnt; do
        [ -n "$mnt" ] && { echo "Unmounting NFS: $mnt"; umount -f "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true; }
    done
    mount | grep " type nfs4" | awk "{print \$3}" | while read mnt; do
        [ -n "$mnt" ] && { echo "Unmounting NFS4: $mnt"; umount -f "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true; }
    done
    for pipefs in /run/rpc_pipefs /var/lib/nfs/rpc_pipefs /proc/fs/nfsd; do
        mount | grep -q "$pipefs" && { echo "Unmounting: $pipefs"; umount -f "$pipefs" 2>/dev/null || umount -l "$pipefs" 2>/dev/null || true; }
    done
}

drop_caches() {
    echo ""
    echo "=== Dropping filesystem caches ==="
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 1
}

try_unload_modules() {
    NFS_MODULES="nfsd nfsv4 nfsv3 nfs rpcsec_gss_krb5 auth_rpcgss nfs_acl lockd grace fscache netfs sunrpc rpcrdma compat_nfs_ssc"
    for mod in $NFS_MODULES; do
        if cat /proc/modules | grep -q "^$mod "; then
            usage=$(cat /proc/modules | grep "^$mod " | awk "{print \$3}")
            if [ "$usage" = "0" ]; then
                echo "Unloading $mod (usage: 0)..."
                rmmod "$mod" 2>/dev/null && echo "  -> Unloaded $mod" || true
            else
                echo "Trying $mod (usage: $usage)..."
                rmmod "$mod" 2>/dev/null && echo "  -> Unloaded $mod" || true
            fi
        fi
    done
}

stop_kubelet() {
    echo ""
    echo "=== FALLBACK: Temporarily stopping kubelet ==="
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop kubelet 2>/dev/null && echo "Kubelet stopped" || echo "Could not stop kubelet"
    else
        pkill -STOP kubelet 2>/dev/null || true
    fi
    KUBELET_STOPPED=1
    sleep 3
}

start_kubelet() {
    if [ "$KUBELET_STOPPED" = "1" ]; then
        echo ""
        echo "=== Restarting kubelet ==="
        if command -v systemctl >/dev/null 2>&1; then
            systemctl unmask rpcbind.socket rpcbind 2>/dev/null || true
            systemctl start kubelet 2>/dev/null && echo "Kubelet started" || echo "Could not start kubelet"
        else
            pkill -CONT kubelet 2>/dev/null || true
        fi
        KUBELET_STOPPED=0
    fi
}

check_sunrpc_unloaded() {
    ! cat /proc/modules | grep -q "^sunrpc "
}

# Main logic
stop_nfs_services
kill_rpc_processes
unmount_nfs_filesystems
drop_caches

echo ""
echo "=== Starting iterative module unload ==="
echo "Target: Unload sunrpc module"
echo "Max attempts: $MAX_ATTEMPTS"
echo ""

attempt=0
while [ $attempt -lt $MAX_ATTEMPTS ]; do
    attempt=$((attempt + 1))
    
    if check_sunrpc_unloaded; then
        echo ""
        echo "=========================================="
        echo "SUCCESS: sunrpc module is not loaded!"
        echo "=========================================="
        start_kubelet
        
        # Unmask and start services for KMM
        echo ""
        echo "=== Unmasking and starting NFS/RPC services for KMM ==="
        systemctl unmask rpcbind.socket rpcbind rpc-statd nfs-client.target nfs-common 2>/dev/null || true
        
        # Start services so they are ready when KMM loads modules
        echo "Starting rpcbind..."
        systemctl start rpcbind.socket 2>/dev/null || true
        systemctl start rpcbind 2>/dev/null || true
        
        echo "Starting rpc-statd (required for NFS locking)..."
        systemctl start rpc-statd 2>/dev/null || true
        
        echo "Starting nfs-client.target..."
        systemctl start nfs-client.target 2>/dev/null || true
        systemctl start nfs-common 2>/dev/null || true
        
        echo "Services started, ready for KMM deployment"
        exit 0
    fi
    
    echo "--- Attempt $attempt/$MAX_ATTEMPTS ---"
    echo "Current NFS modules:"
    cat /proc/modules | grep -E "(sunrpc|nfs|rpc|lockd|grace)" | awk "{print \"  \" \$1 \" (usage: \" \$3 \")\"}" | head -10 || true
    
    if [ $attempt -eq $((MAX_ATTEMPTS / 2)) ] && [ "$KUBELET_STOPPED" = "0" ] && [ "$ALLOW_KUBELET_STOP" = "1" ]; then
        echo ""
        echo "=== Halfway point, trying more aggressive approach ==="
        stop_kubelet
        stop_nfs_services
        kill_rpc_processes
        unmount_nfs_filesystems
        drop_caches
    fi
    
    if [ $((attempt % 10)) -eq 0 ]; then
        echo "=== Periodic cleanup ==="
        kill_rpc_processes
        unmount_nfs_filesystems
        drop_caches
    fi
    
    try_unload_modules
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    echo ""
    sleep $SLEEP_BETWEEN
done

echo ""
echo "ERROR: Failed to unload sunrpc after $MAX_ATTEMPTS attempts"
start_kubelet
exit 1
'

    # Create ConfigMap and run unload-only pod
    POD_NAME="vastnfs-unload-$(echo "$NODE_NAME" | tr '.' '-' | cut -c1-20)-$$"
    CM_NAME="vastnfs-unload-script-$$"
    
    kubectl create configmap "$CM_NAME" -n "$NAMESPACE" --from-literal=unload.sh="$UNLOAD_ONLY_SCRIPT" -o yaml --dry-run=client | kubectl apply -f -
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NAMESPACE
spec:
  nodeName: $NODE_NAME
  hostPID: true
  hostNetwork: true
  restartPolicy: Never
  serviceAccountName: $PREPARE_SERVICE_ACCOUNT
  tolerations:
  - operator: Exists
  volumes:
  - name: script
    configMap:
      name: $CM_NAME
      defaultMode: 0755
  - name: host-tmp
    hostPath:
      path: /tmp
      type: Directory
  containers:
  - name: unload
    image: $HELPER_IMAGE
    securityContext:
      privileged: true
      capabilities:
        add:
        - SYS_MODULE
        - SYS_ADMIN
    volumeMounts:
    - name: script
      mountPath: /scripts
    - name: host-tmp
      mountPath: /host-tmp
    command:
    - /bin/sh
    - -c
    - |
      cp /scripts/unload.sh /host-tmp/vastnfs-unload-$$.sh
      chmod +x /host-tmp/vastnfs-unload-$$.sh
      nsenter -t 1 -m -u -i -n -- /bin/sh /tmp/vastnfs-unload-$$.sh
      EXIT_CODE=\$?
      rm -f /host-tmp/vastnfs-unload-$$.sh
      exit \$EXIT_CODE
EOF

    print_info "Waiting for unload pod to start..."
    sleep 5
    
    print_info "Streaming unload logs..."
    kubectl logs -f $POD_NAME -n "$NAMESPACE" 2>/dev/null &
    LOG_PID=$!
    
    for i in $(seq 1 300); do
        POD_PHASE=$(kubectl get pod $POD_NAME -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$POD_PHASE" = "Succeeded" ] || [ "$POD_PHASE" = "Failed" ]; then
            break
        fi
        WAITING_REASON=$(kubectl get pod $POD_NAME -n "$NAMESPACE" -o jsonpath='{.status.initContainerStatuses[*].state.waiting.reason} {.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null || echo "")
        if echo "$WAITING_REASON" | grep -qE "ErrImagePull|ImagePullBackOff"; then
            print_error "Helper pod image pull failed: $WAITING_REASON"
            break
        fi
        sleep 2
    done
    
    kill $LOG_PID 2>/dev/null || true
    wait $LOG_PID 2>/dev/null || true
    
    POD_PHASE=$(kubectl get pod $POD_NAME -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    EXIT_CODE=$(kubectl get pod $POD_NAME -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "1")
    
    kubectl delete pod $POD_NAME -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    kubectl delete configmap $CM_NAME -n "$NAMESPACE" 2>/dev/null || true
    
    if [ "$POD_PHASE" = "Succeeded" ] && [ "$EXIT_CODE" = "0" ]; then
        print_success "Modules unloaded successfully"
    else
        print_error "Module unload failed (phase: $POD_PHASE, exit: $EXIT_CODE)"
        print_info "Node is still cordoned. To uncordon: kubectl uncordon $NODE_NAME"
        exit 1
    fi
    
    # Step 4: Uncordon the node
    print_step "Step 4: Uncordoning node for KMM deployment..."
    kubectl uncordon "$NODE_NAME"
    print_success "Node uncordoned"
    
    echo ""
    print_success "=========================================="
    print_success "Node $NODE_NAME preparation complete!"
    print_success "Modules unloaded, KMM will deploy VAST NFS"
    print_success "=========================================="
    exit 0
fi

# Full mode: Get kernel version and load modules
print_step "Step 3: Getting kernel version..."

KVER_OUTPUT=$(kubectl run "get-kver-$(echo "$NODE_NAME" | tr '.' '-' | cut -c1-15)-$$" -n "$NAMESPACE" --rm -i --restart=Never \
    --image="$HELPER_IMAGE" \
    --overrides='{
        "spec": {
            "nodeName": "'"$NODE_NAME"'",
            "hostPID": true,
            "serviceAccountName": "'"$PREPARE_SERVICE_ACCOUNT"'",
            "containers": [{
                "name": "kver",
                "image": "'"$HELPER_IMAGE"'",
                "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "uname", "-r"],
                "securityContext": {"privileged": true}
            }],
            "tolerations": [{"operator": "Exists"}]
        }
    }' 2>&1 | grep -v "^pod " | grep -v "command prompt" | grep -v "^If you" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -1 | tr -d '\r\n')
KERNEL_VERSION="${KVER_OUTPUT}"
print_info "Kernel version: $KERNEL_VERSION"

# Verify required environment variables are set
if [ -z "$VASTNFS_VERSION" ]; then
    print_error "VASTNFS_VERSION environment variable is not set!"
    print_error "Please set it before running this script."
    print_error "Example: export VASTNFS_VERSION=4.5.5"
    print_info "Or use --unload-only to just unload modules and let KMM handle loading"
    kubectl uncordon "$NODE_NAME" 2>/dev/null || true
    exit 1
fi

if [ -z "$KMM_IMG_REPO" ]; then
    print_error "KMM_IMG_REPO environment variable is not set!"
    print_error "Please set it before running this script."
    print_error "Example: export KMM_IMG_REPO=myregistry:5000/vastnfs"
    print_info "Or use --unload-only to just unload modules and let KMM handle loading"
    kubectl uncordon "$NODE_NAME" 2>/dev/null || true
    exit 1
fi

VASTNFS_IMAGE=$(select_vastnfs_image "${KMM_IMG_REPO}:${KERNEL_VERSION}-vastnfs-${VASTNFS_VERSION}")
print_info "VAST NFS image: $VASTNFS_IMAGE"
RESOLVED_VASTNFS_IMAGE=$(resolve_image_reference "$VASTNFS_IMAGE")
if [[ "$RESOLVED_VASTNFS_IMAGE" != "$VASTNFS_IMAGE" ]]; then
    print_info "Resolved image digest: $RESOLVED_VASTNFS_IMAGE"
    VASTNFS_IMAGE="$RESOLVED_VASTNFS_IMAGE"
fi

# Step 4: Copy modules and vastnfs-ctl, then reload using vastnfs-ctl
print_step "Step 4: Copying VAST NFS modules and reloading NFS stack..."

# The reload script that runs on the node
# Strategy:
# 1. Copy VAST NFS modules from container image to host
# 2. Copy vastnfs-ctl to host
# 3. Run depmod to update module dependencies
# 4. Try vastnfs-ctl reload (handles unload + reload automatically)
# 5. If vastnfs-ctl reload fails, fall back to manual method
RELOAD_SCRIPT='#!/bin/sh
# VAST NFS Reload Script using vastnfs-ctl
# Primary method: vastnfs-ctl reload
# Fallback: Manual unload/load process

MAX_ATTEMPTS='"$MAX_ATTEMPTS"'
ALLOW_KUBELET_STOP='"$ALLOW_KUBELET_STOP"'
SLEEP_BETWEEN=3
KUBELET_STOPPED=0
KVER="'"$KERNEL_VERSION"'"
MODULE_ROOT=/tmp/vastnfs-opt
MODULE_DIR=$MODULE_ROOT/lib/modules/$KVER/extra

echo "=== Host OS Information ==="
cat /etc/os-release 2>/dev/null | head -5 || echo "Unknown OS"
echo "Kernel: $(uname -r)"
echo ""

# Check if VAST NFS is already loaded with correct version
if cat /sys/module/sunrpc/parameters/nfs_bundle_version 2>/dev/null | grep -q "vastdata.*'"$VASTNFS_VERSION"'"; then
    echo "=========================================="
    echo "VAST NFS '"$VASTNFS_VERSION"' is already loaded!"
    echo "=========================================="
    cat /sys/module/sunrpc/parameters/nfs_bundle_version
    exit 0
fi

echo "=== Step 1: Verifying VAST NFS modules are in place ==="
if [ ! -d "$MODULE_DIR" ] || ! find "$MODULE_DIR" -name '*.ko' -type f | grep -q .; then
    echo "ERROR: VAST NFS modules not found under $MODULE_DIR"
    echo "Modules should be copied by the init container."
    exit 1
fi
echo "Modules found:"
find "$MODULE_DIR" -name '*.ko' -type f | sort

echo ""
echo "=== Step 2: Ensuring vastnfs-ctl is available ==="
if [ ! -x /usr/local/bin/vastnfs-ctl ]; then
    echo "WARNING: vastnfs-ctl not found at /usr/local/bin/vastnfs-ctl"
    echo "Will use manual fallback method."
    VASTNFS_CTL_AVAILABLE=0
else
    echo "vastnfs-ctl found at /usr/local/bin/vastnfs-ctl"
    VASTNFS_CTL_AVAILABLE=1
fi

echo ""
echo "=== Step 3: Running depmod to update module dependencies ==="
depmod -b "$MODULE_ROOT" "$KVER"
echo "depmod completed"

echo ""
echo "=========================================="
echo "=== Step 4: Attempting vastnfs-ctl reload ==="
echo "=========================================="
echo "This will unload existing NFS modules and reload with VAST NFS."
echo ""

# Try vastnfs-ctl reload
if [ "$VASTNFS_CTL_AVAILABLE" = "1" ] && /usr/local/bin/vastnfs-ctl reload; then
    echo ""
    echo "=========================================="
    echo "SUCCESS: vastnfs-ctl reload completed!"
    echo "=========================================="
    echo ""
    echo "=== VAST NFS Version ==="
    cat /sys/module/sunrpc/parameters/nfs_bundle_version 2>/dev/null || echo "Could not read version"
    echo ""
    echo "=== vastnfs-ctl status ==="
    /usr/local/bin/vastnfs-ctl status 2>/dev/null || true
    
    # Start required NFS userspace services (rpc.statd for locking)
    echo ""
    echo "=== Starting NFS/RPC services ==="
    systemctl unmask rpcbind.socket rpcbind rpc-statd nfs-client.target nfs-common 2>/dev/null || true
    systemctl start rpcbind.socket 2>/dev/null || true
    systemctl start rpcbind 2>/dev/null || true
    systemctl start rpc-statd 2>/dev/null || true
    systemctl start nfs-client.target 2>/dev/null || true
    systemctl start nfs-common 2>/dev/null || true
    
    # Verify rpc.statd is running
    if pgrep -x "rpc.statd" > /dev/null 2>&1; then
        echo "rpc.statd is running (NFS locking enabled)"
    else
        echo "WARNING: Starting rpc.statd directly..."
        /usr/sbin/rpc.statd 2>/dev/null || true
    fi
    
    exit 0
fi

echo ""
echo "=========================================="
echo "WARNING: vastnfs-ctl reload failed!"
echo "Falling back to manual unload/load method..."
echo "=========================================="
echo ""

# ==================== FALLBACK: MANUAL METHOD ====================

# Function to aggressively stop all NFS/RPC services
stop_nfs_services() {
    echo "=== Stopping and masking NFS/RPC services ==="
    
    # Try systemd first (most modern distros)
    if command -v systemctl >/dev/null 2>&1; then
        echo "Using systemd..."
        # Stop services in dependency order
        for svc in nfs-server nfsdcld nfs-mountd nfs-idmapd rpc-gssd nfs-blkmap \
                   nfs-client.target rpc-statd rpcbind.socket rpcbind; do
            systemctl stop "$svc" 2>/dev/null && echo "  Stopped: $svc" || true
        done
        # Disable and mask to prevent auto-restart
        for svc in rpcbind.socket rpcbind rpc-statd nfs-client.target; do
            systemctl disable "$svc" 2>/dev/null || true
            systemctl mask "$svc" 2>/dev/null && echo "  Masked: $svc" || true
        done
    fi
    
    # Also try SysV init (older distros or if systemd failed)
    if command -v service >/dev/null 2>&1; then
        echo "Trying SysV init services..."
        for svc in rpcbind nfs nfs-kernel-server nfs-common portmap; do
            service "$svc" stop 2>/dev/null && echo "  Stopped: $svc" || true
        done
    fi
    
    # Also try direct init scripts (very old systems)
    for init_script in /etc/init.d/rpcbind /etc/init.d/nfs /etc/init.d/nfs-common /etc/init.d/portmap; do
        if [ -x "$init_script" ]; then
            "$init_script" stop 2>/dev/null && echo "  Stopped: $init_script" || true
        fi
    done
}

# Function to kill all RPC-related processes
kill_rpc_processes() {
    echo ""
    echo "=== Killing any remaining RPC processes ==="
    
    # Use pkill if available, otherwise use killall or manual approach
    if command -v pkill >/dev/null 2>&1; then
        pkill -9 rpcbind 2>/dev/null && echo "  Killed: rpcbind" || true
        pkill -9 rpc.statd 2>/dev/null && echo "  Killed: rpc.statd" || true
        pkill -9 rpc.mountd 2>/dev/null && echo "  Killed: rpc.mountd" || true
        pkill -9 rpc.idmapd 2>/dev/null && echo "  Killed: rpc.idmapd" || true
        pkill -9 rpc.gssd 2>/dev/null && echo "  Killed: rpc.gssd" || true
        pkill -9 nfsd 2>/dev/null && echo "  Killed: nfsd" || true
    elif command -v killall >/dev/null 2>&1; then
        killall -9 rpcbind rpc.statd rpc.mountd rpc.idmapd rpc.gssd nfsd 2>/dev/null || true
    else
        # Manual approach using /proc
        for proc in rpcbind rpc.statd rpc.mountd rpc.idmapd rpc.gssd nfsd; do
            for pid in $(ps aux 2>/dev/null | grep "$proc" | grep -v grep | awk "{print \$2}"); do
                kill -9 "$pid" 2>/dev/null && echo "  Killed: $proc (PID $pid)" || true
            done
        done
    fi
    sleep 1
}

# Function to unmount all NFS-related filesystems
unmount_nfs_filesystems() {
    echo ""
    echo "=== Unmounting NFS/RPC filesystems ==="
    
    # Unmount any NFS mounts (force, then lazy if needed)
    mount | grep " type nfs" | awk "{print \$3}" | while read mnt; do
        if [ -n "$mnt" ]; then
            echo "Unmounting NFS: $mnt"
            umount -f "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
        fi
    done
    
    mount | grep " type nfs4" | awk "{print \$3}" | while read mnt; do
        if [ -n "$mnt" ]; then
            echo "Unmounting NFS4: $mnt"
            umount -f "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
        fi
    done
    
    # Unmount rpc_pipefs (various possible locations)
    for pipefs in /run/rpc_pipefs /var/lib/nfs/rpc_pipefs /proc/fs/nfsd; do
        if mount | grep -q "$pipefs"; then
            echo "Unmounting: $pipefs"
            umount -f "$pipefs" 2>/dev/null || umount -l "$pipefs" 2>/dev/null || true
        fi
    done
    
    # Also unmount any sunrpc filesystems
    mount | grep "type rpc_pipefs" | awk "{print \$3}" | while read mnt; do
        if [ -n "$mnt" ]; then
            echo "Unmounting rpc_pipefs: $mnt"
            umount -f "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
        fi
    done
}

# Function to drop filesystem caches
drop_caches() {
    echo ""
    echo "=== Dropping filesystem caches ==="
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 1
}

# Function to try unloading all NFS modules
try_unload_modules() {
    # List of NFS modules to unload (in dependency order, most dependent first)
    NFS_MODULES="nfsd nfsv4 nfsv3 nfs rpcsec_gss_krb5 auth_rpcgss nfs_acl lockd grace fscache netfs sunrpc rpcrdma compat_nfs_ssc nfs_layout_nfsv41_files nfs_layout_flexfiles"
    
    # Try to unload each module
    for mod in $NFS_MODULES; do
        if cat /proc/modules | grep -q "^$mod "; then
            # Get usage count (3rd field in /proc/modules)
            usage=$(cat /proc/modules | grep "^$mod " | awk "{print \$3}")
            if [ "$usage" = "0" ]; then
                echo "Unloading $mod (usage: 0)..."
                if rmmod "$mod" 2>/dev/null; then
                    echo "  -> Unloaded $mod"
                fi
            else
                echo "Trying $mod (usage: $usage)..."
                rmmod "$mod" 2>/dev/null && echo "  -> Unloaded $mod" || true
            fi
        fi
    done
    
    # Also try to unload sunrpc with all its dependencies at once
    rmmod sunrpc nfsv4 auth_rpcgss lockd nfsv3 rpcsec_gss_krb5 nfs_acl nfs 2>/dev/null || true
}

# Function to load VAST NFS modules
load_vastnfs_modules() {
    echo ""
    echo "=== Loading VAST NFS modules ==="
    
    # Show module info for debugging
    echo "Module location:"
    SUNRPC_KO=$(find "$MODULE_DIR" -name sunrpc.ko -type f | head -1)
    ls -la "$SUNRPC_KO" 2>/dev/null || echo "sunrpc.ko not found under $MODULE_DIR"
    echo ""
    
    # Try modprobe first
    if modprobe -d "$MODULE_ROOT" -v sunrpc 2>&1; then
        echo "Loaded: sunrpc (via modprobe)"
    else
        echo "modprobe sunrpc failed, trying insmod directly..."
        echo ""
        echo "=== Diagnostic info ==="
        echo "Kernel: $(uname -r)"
        modinfo "$SUNRPC_KO" 2>&1 | head -10 || true
        echo ""
        
        # Try insmod directly with verbose output
        if [ -n "$SUNRPC_KO" ] && insmod "$SUNRPC_KO" 2>&1; then
            echo "Loaded: sunrpc (via insmod)"
        else
            echo "FAILED: sunrpc"
            echo ""
            echo "=== dmesg (last 15 lines) ==="
            dmesg | tail -15
            echo ""
            echo "=== Checking module signature ==="
            if command -v mokutil >/dev/null 2>&1; then
                mokutil --sb-state 2>/dev/null || echo "Could not check secure boot state"
            fi
            echo ""
            echo "=== Module file info ==="
            file "$SUNRPC_KO" 2>/dev/null || true
            return 1
        fi
    fi
    
    modprobe -d "$MODULE_ROOT" -v nfs && echo "Loaded: nfs" || { echo "FAILED: nfs"; dmesg | tail -10; return 1; }
    modprobe -d "$MODULE_ROOT" -v nfsv3 2>/dev/null && echo "Loaded: nfsv3" || true
    modprobe -d "$MODULE_ROOT" -v nfsv4 2>/dev/null && echo "Loaded: nfsv4" || true
    
    # Start required NFS userspace services
    echo ""
    echo "=== Unmasking and starting NFS/RPC services ==="
    # Unmask all NFS-related services that were masked during unload
    systemctl unmask rpcbind.socket rpcbind rpc-statd nfs-client.target nfs-common 2>/dev/null || true
    
    # Start services in dependency order
    echo "Starting rpcbind..."
    systemctl start rpcbind.socket 2>/dev/null || true
    systemctl start rpcbind 2>/dev/null || true
    
    echo "Starting rpc-statd (required for NFS locking)..."
    systemctl start rpc-statd 2>/dev/null || true
    
    echo "Starting nfs-client.target..."
    systemctl start nfs-client.target 2>/dev/null || true
    
    # On Debian/Ubuntu, also try nfs-common
    systemctl start nfs-common 2>/dev/null || true
    
    # Verify rpc.statd is running
    echo ""
    echo "=== Verifying NFS services ==="
    if pgrep -x "rpc.statd" > /dev/null 2>&1; then
        echo "rpc.statd is running"
    else
        echo "WARNING: rpc.statd may not be running, trying to start..."
        # Try direct start via service command as fallback
        service rpc-statd start 2>/dev/null || true
        /usr/sbin/rpc.statd 2>/dev/null || true
    fi
    
    return 0
}

# Function to stop kubelet temporarily
stop_kubelet() {
    echo ""
    echo "=========================================="
    echo "=== FALLBACK: Temporarily stopping kubelet ==="
    echo "=========================================="
    echo "This is needed because kubelet may be holding NFS references."
    echo ""
    
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop kubelet 2>/dev/null && echo "Kubelet stopped" || echo "Could not stop kubelet"
    else
        # Try direct kill
        pkill -STOP kubelet 2>/dev/null || true
    fi
    KUBELET_STOPPED=1
    sleep 3
}

# Function to start kubelet
start_kubelet() {
    if [ "$KUBELET_STOPPED" = "1" ]; then
        echo ""
        echo "=== Restarting kubelet ==="
        if command -v systemctl >/dev/null 2>&1; then
            # Unmask rpcbind first in case KMM needs it
            systemctl unmask rpcbind.socket rpcbind 2>/dev/null || true
            systemctl start kubelet 2>/dev/null && echo "Kubelet started" || echo "Could not start kubelet"
        else
            pkill -CONT kubelet 2>/dev/null || true
        fi
        KUBELET_STOPPED=0
    fi
}

# Function to check if sunrpc is unloaded
check_sunrpc_unloaded() {
    if ! cat /proc/modules | grep -q "^sunrpc "; then
        return 0  # Success - sunrpc is not loaded
    fi
    return 1  # Failed - sunrpc is still loaded
}

# Function to check if VAST NFS is loaded
check_vastnfs_loaded() {
    if cat /sys/module/sunrpc/parameters/nfs_bundle_version 2>/dev/null | grep -q vastdata; then
        return 0  # Success - VAST NFS is loaded
    fi
    return 1  # Failed - VAST NFS is not loaded
}

# ==================== MANUAL FALLBACK MAIN LOGIC ====================

# Initial service stop and cleanup
stop_nfs_services
kill_rpc_processes
unmount_nfs_filesystems
drop_caches

echo ""
echo "=== Starting iterative module unload ==="
echo "Target: Unload sunrpc module, then load VAST NFS"
echo "Max attempts: $MAX_ATTEMPTS"
if [ "$ALLOW_KUBELET_STOP" = "1" ]; then
    echo "Kubelet stop fallback at: attempt $((MAX_ATTEMPTS / 2))"
else
    echo "Kubelet stop fallback: DISABLED"
fi
echo ""

attempt=0
while [ $attempt -lt $MAX_ATTEMPTS ]; do
    attempt=$((attempt + 1))
    
    # Check if sunrpc is unloaded
    if check_sunrpc_unloaded; then
        echo ""
        echo "=========================================="
        echo "SUCCESS: sunrpc module is not loaded!"
        echo "=========================================="
        echo ""
        
        # Now load VAST NFS modules
        if load_vastnfs_modules; then
            echo ""
            echo "=== VAST NFS Version ==="
            cat /sys/module/sunrpc/parameters/nfs_bundle_version 2>/dev/null || echo "Could not read version"
            echo ""
            echo "=== Loaded NFS Modules ==="
            lsmod | grep -E "sunrpc|nfs|lockd" | head -10
            
            # Make sure kubelet is running
            start_kubelet
            exit 0
        else
            echo "ERROR: Failed to load VAST NFS modules"
            start_kubelet
            exit 1
        fi
    fi
    
    echo "--- Attempt $attempt/$MAX_ATTEMPTS ---"
    
    # Show current state
    echo "Current NFS modules:"
    cat /proc/modules | grep -E "(sunrpc|nfs|rpc|lockd|grace|fscache)" | awk "{print \"  \" \$1 \" (usage: \" \$3 \")\"}" | head -10 || true
    
    # At halfway point, try stopping kubelet if still failing (and allowed)
    if [ $attempt -eq $((MAX_ATTEMPTS / 2)) ] && [ "$KUBELET_STOPPED" = "0" ]; then
        echo ""
        echo "=== Halfway point reached, trying more aggressive approach ==="
        
        if [ "$ALLOW_KUBELET_STOP" = "1" ]; then
            stop_kubelet
        else
            echo "Kubelet stop is disabled (--no-kubelet-stop). Continuing without stopping kubelet."
        fi
        
        # Re-run all cleanup steps
        stop_nfs_services
        kill_rpc_processes
        unmount_nfs_filesystems
        drop_caches
    fi
    
    # Every 10 attempts, re-run service stop and process kill
    if [ $((attempt % 10)) -eq 0 ]; then
        echo "=== Periodic cleanup ==="
        kill_rpc_processes
        unmount_nfs_filesystems
        drop_caches
    fi
    
    # Try to unload modules
    try_unload_modules
    
    # Drop caches
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    echo ""
    sleep $SLEEP_BETWEEN
done

# If we get here, we failed
echo ""
echo "=========================================="
echo "ERROR: Failed to unload sunrpc after $MAX_ATTEMPTS attempts"
echo "=========================================="
echo ""

# Make sure kubelet is running before we exit
start_kubelet

echo "=== Current module state ==="
cat /proc/modules | grep -E "(sunrpc|nfs|rpc|lockd|grace|fscache)" | awk "{print \"  \" \$1 \" (usage: \" \$3 \")\"}" || true
echo ""

echo "=== Possible causes ==="
echo "1. A process is still using NFS (check with: lsof | grep nfs)"
echo "2. A DaemonSet pod is using NFS volumes"
echo "3. kubelet has NFS mounts in /var/lib/kubelet"
echo "4. Container runtime has NFS references"
echo ""

echo "=== Debug: Active NFS mounts ==="
mount | grep -E "(nfs|rpc)" || echo "No NFS mounts found"
echo ""

echo "=== Debug: RPC processes still running ==="
ps aux | grep -E "(rpc|nfs)" | grep -v grep || echo "No RPC processes found"
echo ""

echo "=== Debug: Kubelet volume mounts ==="
mount | grep /var/lib/kubelet | head -5 || echo "No kubelet mounts found"
echo ""

echo "=== Suggestion ==="
echo "Try rebooting the node: kubectl debug node/<node-name> -it --image=alpine --profile=sysadmin -- chroot /host reboot"
echo ""

exit 1
'

# Run the reload script on the node using a privileged pod with init container for copying modules
print_info "Running VAST NFS reload on node (this may take several minutes)..."
print_info "Primary method: vastnfs-ctl reload"
print_info "Fallback: Manual unload/load process"

# Create a unique pod name
POD_NAME="vastnfs-prep-$(echo "$NODE_NAME" | tr '.' '-' | cut -c1-20)-$$"
CM_NAME="vastnfs-reload-script-$$"

# Create a ConfigMap with the reload script (more reliable than env vars for large scripts)
kubectl create configmap "$CM_NAME" -n "$NAMESPACE" --from-literal=reload.sh="$RELOAD_SCRIPT" -o yaml --dry-run=client | kubectl apply -f -

# Create the pod with:
# 1. Init container: copies modules and vastnfs-ctl from VASTNFS_IMAGE to host
# 2. Main container: runs the reload script (vastnfs-ctl reload with fallback)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NAMESPACE
spec:
  nodeName: $NODE_NAME
  hostPID: true
  hostNetwork: true
  restartPolicy: Never
  serviceAccountName: $PREPARE_SERVICE_ACCOUNT
  tolerations:
  - operator: Exists
  volumes:
  - name: script
    configMap:
      name: $CM_NAME
      defaultMode: 0755
  - name: host-tmp
    hostPath:
      path: /tmp
      type: Directory
  - name: host-modules
    hostPath:
      path: /lib/modules
      type: Directory
  initContainers:
  - name: copy-modules
    image: $VASTNFS_IMAGE
    imagePullPolicy: Always
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-modules
      mountPath: /host-modules
    - name: host-tmp
      mountPath: /host-tmp
    command: ["/bin/sh", "-c"]
    args:
    - |
      set -e
      KVER="$KERNEL_VERSION"
      echo "=== Copying VAST NFS modules to host ==="
      MODULE_ROOT=/host-tmp/vastnfs-opt
      rm -rf "\$MODULE_ROOT"
      mkdir -p "\$MODULE_ROOT/lib/modules/\$KVER"
      cp -a /opt/lib/modules/\$KVER/extra "\$MODULE_ROOT/lib/modules/\$KVER/"
      cp /opt/lib/modules/\$KVER/modules.* "\$MODULE_ROOT/lib/modules/\$KVER/" 2>/dev/null || true
      echo "Modules copied:"
      find "\$MODULE_ROOT/lib/modules/\$KVER/extra" -name '*.ko' -type f | sort
      
      # Copy vastnfs-ctl to host /tmp (will be moved by main container via nsenter)
      if [ -f /opt/bin/vastnfs-ctl ]; then
        echo ""
        echo "=== Copying vastnfs-ctl to /tmp ==="
        cp /opt/bin/vastnfs-ctl /host-tmp/vastnfs-ctl
        chmod +x /host-tmp/vastnfs-ctl
        echo "vastnfs-ctl copied to host /tmp/"
      else
        echo "WARNING: vastnfs-ctl not found in image"
      fi
      echo ""
      echo "=== Init container completed ==="
  containers:
  - name: reload
    image: $HELPER_IMAGE
    securityContext:
      privileged: true
      capabilities:
        add:
        - SYS_MODULE
        - SYS_ADMIN
    volumeMounts:
    - name: script
      mountPath: /scripts
    - name: host-tmp
      mountPath: /host-tmp
    command:
    - /bin/sh
    - -c
    - |
      # First, install vastnfs-ctl to host /usr/local/bin via nsenter
      if [ -f /host-tmp/vastnfs-ctl ]; then
        echo "=== Installing vastnfs-ctl to host ==="
        nsenter -t 1 -m -u -i -n -- mkdir -p /usr/local/bin
        cat /host-tmp/vastnfs-ctl | nsenter -t 1 -m -u -i -n -- tee /usr/local/bin/vastnfs-ctl > /dev/null
        nsenter -t 1 -m -u -i -n -- chmod +x /usr/local/bin/vastnfs-ctl
        echo "vastnfs-ctl installed to /usr/local/bin/"
        rm -f /host-tmp/vastnfs-ctl
      fi
      
      # Copy reload script to host's /tmp so nsenter can access it
      cp /scripts/reload.sh /host-tmp/vastnfs-reload-$$.sh
      chmod +x /host-tmp/vastnfs-reload-$$.sh
      
      # Run the reload script via nsenter in host namespace
      nsenter -t 1 -m -u -i -n -- /bin/sh /tmp/vastnfs-reload-$$.sh
      EXIT_CODE=\$?
      
      # Cleanup
      rm -f /host-tmp/vastnfs-reload-$$.sh
      exit \$EXIT_CODE
EOF

# Wait for pod to start
print_info "Waiting for cleanup pod to start..."
sleep 5

# Stream logs
print_info "Streaming cleanup logs..."
kubectl logs -f $POD_NAME -n "$NAMESPACE" 2>/dev/null &
LOG_PID=$!

# Wait for pod to complete (max 10 minutes)
for i in $(seq 1 300); do
    POD_PHASE=$(kubectl get pod $POD_NAME -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$POD_PHASE" = "Succeeded" ] || [ "$POD_PHASE" = "Failed" ]; then
        break
    fi
    WAITING_REASON=$(kubectl get pod $POD_NAME -n "$NAMESPACE" -o jsonpath='{.status.initContainerStatuses[*].state.waiting.reason} {.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null || echo "")
    if echo "$WAITING_REASON" | grep -qE "ErrImagePull|ImagePullBackOff"; then
        print_error "Prep pod image pull failed: $WAITING_REASON"
        break
    fi
    sleep 2
done

# Kill the log streaming
kill $LOG_PID 2>/dev/null || true
wait $LOG_PID 2>/dev/null || true

# Get the exit code from the pod
UNLOAD_STATUS=0
POD_PHASE=$(kubectl get pod $POD_NAME -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
EXIT_CODE=$(kubectl get pod $POD_NAME -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
if [ -z "$EXIT_CODE" ]; then
    EXIT_CODE=$(kubectl get pod $POD_NAME -n "$NAMESPACE" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "1")
fi

if [ "$POD_PHASE" = "Succeeded" ] && [ "$EXIT_CODE" = "0" ]; then
    print_success "VAST NFS reload completed successfully"
else
    print_error "VAST NFS reload pod failed (phase: $POD_PHASE, exit: $EXIT_CODE)"
    print_info "copy-modules logs:"
    kubectl logs $POD_NAME -n "$NAMESPACE" -c copy-modules --tail=80 2>/dev/null || true
    print_info "reload logs:"
    kubectl logs $POD_NAME -n "$NAMESPACE" -c reload --tail=80 2>/dev/null || true
    UNLOAD_STATUS=1
fi

# Cleanup the pod and ConfigMap. Keep failed pods when explicitly requested for
# interactive debugging.
if [ $UNLOAD_STATUS -eq 0 ] || [ "${KEEP_FAILED_PREP_POD:-false}" != "true" ]; then
    kubectl delete pod $POD_NAME -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    kubectl delete configmap $CM_NAME -n "$NAMESPACE" 2>/dev/null || true
else
    print_warning "Keeping failed pod for debugging: $POD_NAME"
fi

if [ $UNLOAD_STATUS -ne 0 ]; then
    print_error "VAST NFS reload failed!"
    print_error "The node is still cordoned. Please investigate and retry."
    print_info "To uncordon: kubectl uncordon $NODE_NAME"
    exit 1
fi

# Step 5: Verify VAST NFS is loaded
print_step "Step 5: Verifying VAST NFS is loaded..."
VERIFY_POD="verify-$(echo "$NODE_NAME" | tr '.' '-' | cut -c1-15)-$$"
VASTNFS_VERSION_LOADED=$(kubectl run "$VERIFY_POD" -n "$NAMESPACE" --rm -i --restart=Never \
    --image="$HELPER_IMAGE" \
    --overrides='{
        "spec": {
            "nodeName": "'"$NODE_NAME"'",
            "hostPID": true,
            "serviceAccountName": "'"$PREPARE_SERVICE_ACCOUNT"'",
            "containers": [{
                "name": "verify",
                "image": "'"$HELPER_IMAGE"'",
                "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "cat", "/sys/module/sunrpc/parameters/nfs_bundle_version"],
                "securityContext": {"privileged": true}
            }],
            "tolerations": [{"operator": "Exists"}]
        }
    }' 2>/dev/null | grep -v "command prompt" | grep -v "^pod " | head -1 || echo "UNKNOWN")

if echo "$VASTNFS_VERSION_LOADED" | grep -q vastdata; then
    print_success "VAST NFS is loaded: $VASTNFS_VERSION_LOADED"
else
    print_error "VAST NFS does not appear to be loaded!"
    print_error "Version reported: $VASTNFS_VERSION_LOADED"
    print_error "The node is still cordoned. Please investigate manually."
    print_info "Debug: kubectl debug node/$NODE_NAME -it --image=alpine -- chroot /host cat /sys/module/sunrpc/parameters/nfs_bundle_version"
    print_info "To uncordon: kubectl uncordon $NODE_NAME"
    exit 1
fi

# Step 6: Uncordon the node
print_step "Step 6: Uncordoning node..."
kubectl uncordon "$NODE_NAME"
print_success "Node uncordoned"

# Final verification
print_step "=========================================="
print_step "Final Verification"
print_step "=========================================="

POD_NAME="final-verify-$(echo "$NODE_NAME" | tr '.' '-' | cut -c1-20)-$$"
kubectl run "$POD_NAME" -n "$NAMESPACE" --rm -i --restart=Never \
    --image="$HELPER_IMAGE" \
    --overrides='{
        "spec": {
            "nodeName": "'"$NODE_NAME"'",
            "hostPID": true,
            "serviceAccountName": "'"$PREPARE_SERVICE_ACCOUNT"'",
            "containers": [{
                "name": "verify",
                "image": "'"$HELPER_IMAGE"'",
                "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "sh", "-c", 
                    "echo \"=== Host OS ===\"; cat /etc/os-release 2>/dev/null | head -2 || echo Unknown; echo; echo \"=== VAST NFS Version ===\"; cat /sys/module/sunrpc/parameters/nfs_bundle_version 2>/dev/null || echo NOT_LOADED; echo; echo \"=== vastnfs-ctl status ===\"; /usr/local/bin/vastnfs-ctl status 2>/dev/null || echo vastnfs-ctl not available; echo; echo \"=== Loaded NFS modules ===\"; cat /proc/modules | grep sunrpc || echo None"
                ],
                "securityContext": {"privileged": true}
            }],
            "tolerations": [{"operator": "Exists"}]
        }
    }' 2>/dev/null || true

echo ""
print_success "=========================================="
print_success "Node $NODE_NAME preparation complete!"
print_success "=========================================="
