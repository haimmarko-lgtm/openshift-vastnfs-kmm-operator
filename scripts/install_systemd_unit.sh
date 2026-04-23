#!/bin/bash

# Install the systemd unit to disable in-tree NFS on worker nodes
# This ensures VAST NFS KMM can load modules after node reboots
# Works with any Linux distribution using systemd
#
# Usage: ./install_systemd_unit.sh [node-name]
#        If no node specified, installs on all worker nodes
#
# Environment variables:
#   VASTNFS_HELPER_IMAGE  Override default helper image (default: alpine:latest)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_UNIT="$SCRIPT_DIR/../systemd/disable-intree-nfs.service"
HELPER_IMAGE="${VASTNFS_HELPER_IMAGE:-alpine:latest}"
NAMESPACE="${NAMESPACE:-vastnfs-kmm}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() { echo -e "${GREEN}[STEP]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    echo "Usage: $0 [node-name] [--helper-image IMAGE]"
    echo ""
    echo "Installs the systemd unit to disable in-tree NFS on worker nodes."
    echo "If no node specified, installs on all worker nodes."
    echo ""
    echo "Options:"
    echo "  --helper-image IMAGE  Container image for helper pods (default: alpine:latest)"
    echo ""
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --helper-image)
            HELPER_IMAGE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -z "$TARGET_NODE" ]; then
                TARGET_NODE="$1"
            fi
            shift
            ;;
    esac
done

if [ ! -f "$SYSTEMD_UNIT" ]; then
    print_error "Systemd unit file not found at $SYSTEMD_UNIT"
    exit 1
fi

# Read the systemd unit content
UNIT_CONTENT=$(cat "$SYSTEMD_UNIT")

# Determine which nodes to configure
if [ -n "$TARGET_NODE" ]; then
    NODES="$TARGET_NODE"
else
    # Get all worker nodes (non-control-plane) - works across distributions
    NODES=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || \
        kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints | grep -v "control-plane\|master" | awk '{print $1}' || \
        kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name)
fi

if [ -z "$NODES" ]; then
    print_error "No nodes found"
    exit 1
fi

echo "Installing systemd unit on nodes:"
for node in $NODES; do
    echo "  - $node"
done
echo ""
echo "Helper image: $HELPER_IMAGE"
echo ""

for node in $NODES; do
    print_step "Installing on $node..."
    
    # First check if the node uses systemd
    POD_NAME="check-systemd-$(echo "$node" | tr '.' '-' | cut -c1-15)-$$"
    has_systemd=$(kubectl run "$POD_NAME" -n "$NAMESPACE" --rm -i --restart=Never \
        --image="$HELPER_IMAGE" \
        --overrides='{
            "spec": {
                "nodeName": "'"$node"'",
                "hostPID": true,
                "containers": [{
                    "name": "check",
                    "image": "'"$HELPER_IMAGE"'",
                    "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "sh", "-c", 
                        "command -v systemctl >/dev/null 2>&1 && echo YES || echo NO"],
                    "securityContext": {"privileged": true}
                }],
                "tolerations": [{"operator": "Exists"}]
            }
        }' 2>/dev/null || echo "NO")
    
    if [ "$has_systemd" != "YES" ]; then
        print_warning "Node $node does not use systemd, skipping..."
        continue
    fi
    
    # Install the systemd unit
    POD_NAME="install-unit-$(echo "$node" | tr '.' '-' | cut -c1-15)-$$"
    
    # Create a script that installs the unit
    INSTALL_SCRIPT='#!/bin/sh
cat > /etc/systemd/system/disable-intree-nfs.service << '\''UNITEOF'\''
'"$UNIT_CONTENT"'
UNITEOF
systemctl daemon-reload
systemctl enable disable-intree-nfs.service
echo "SUCCESS: Unit installed and enabled"
'
    
    kubectl run "$POD_NAME" -n "$NAMESPACE" --rm -i --restart=Never \
        --image="$HELPER_IMAGE" \
        --overrides='{
            "spec": {
                "nodeName": "'"$node"'",
                "hostPID": true,
                "hostNetwork": true,
                "containers": [{
                    "name": "install",
                    "image": "'"$HELPER_IMAGE"'",
                    "stdin": true,
                    "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "sh"],
                    "securityContext": {"privileged": true}
                }],
                "tolerations": [{"operator": "Exists"}]
            }
        }' <<< "$INSTALL_SCRIPT" 2>&1 | grep -E "(SUCCESS|error|Error)" || true
    
    print_success "Installed on $node"
done

echo ""
print_info "The systemd unit will take effect on next reboot."
print_info "It will prevent rpcbind from starting, allowing KMM to load VAST NFS modules."
print_info ""
print_info "To verify on a node:"
print_info "  kubectl debug node/<node-name> -it --image=busybox -- chroot /host systemctl status disable-intree-nfs.service"
