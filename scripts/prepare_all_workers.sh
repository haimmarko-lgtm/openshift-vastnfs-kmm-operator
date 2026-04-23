#!/bin/bash

# Prepare All Worker Nodes for VAST NFS - Rolling Update Style
# 
# This script prepares all worker nodes one by one (rolling update)
# Works with any Linux distribution - designed for production NFS systems
#
# Usage: ./prepare_all_workers.sh [--max-attempts N] [--helper-image IMAGE]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}"
    echo "================================================================="
    echo "  $1"
    echo "================================================================="
    echo -e "${NC}"
}

print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

MAX_ATTEMPTS=60
HELPER_IMAGE="${VASTNFS_HELPER_IMAGE:-alpine:latest}"
NAMESPACE="${NAMESPACE:-vastnfs-kmm}"
LABEL_SKIP="${LABEL_SKIP:-false}"
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --max-attempts)
            MAX_ATTEMPTS="$2"
            EXTRA_ARGS="$EXTRA_ARGS --max-attempts $MAX_ATTEMPTS"
            shift 2
            ;;
        --helper-image)
            HELPER_IMAGE="$2"
            EXTRA_ARGS="$EXTRA_ARGS --helper-image $HELPER_IMAGE"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Prepares all worker nodes for VAST NFS KMM in rolling update fashion."
            echo "Processes one node at a time to maintain cluster availability."
            echo "Works with any Linux distribution."
            echo ""
            echo "Options:"
            echo "  --max-attempts N      Max module unload attempts per node (default: 60)"
            echo "  --helper-image IMAGE  Container image for helper pods (default: alpine:latest)"
            echo ""
            echo "Environment variables:"
            echo "  VASTNFS_HELPER_IMAGE  Override default helper image"
            echo "  LABEL_SKIP=true       Ensure nodes are skipped by KMM after success (removes enabled label)"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

print_header "VAST NFS Rolling Update - Worker Node Preparation"

# Get all worker nodes (non-control-plane)
# This method works across different K8s distributions
WORKER_NODES=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints 2>/dev/null | \
    grep -v "node-role.kubernetes.io/control-plane\|node-role.kubernetes.io/master" | \
    awk '{print $1}' || \
    kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -10)

# If that didn't work, try an alternative method
if [ -z "$WORKER_NODES" ]; then
    WORKER_NODES=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || \
        kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name)
fi

if [ -z "$WORKER_NODES" ]; then
    print_error "No worker nodes found"
    exit 1
fi

NODE_COUNT=$(echo "$WORKER_NODES" | wc -w)

echo ""
echo "Worker nodes to prepare ($NODE_COUNT total):"
for node in $WORKER_NODES; do
    status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    os=$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null | cut -c1-30 || echo "Unknown")
    kernel=$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null || echo "Unknown")
    echo "  - $node"
    echo "      OS: $os"
    echo "      Kernel: $kernel"
    echo "      Ready: $status"
done
echo ""
echo "Processing mode: Rolling update (one node at a time)"
echo "Max unload attempts per node: $MAX_ATTEMPTS"
echo "Helper image: $HELPER_IMAGE"
if [ "$LABEL_SKIP" = "true" ]; then
    echo "Label skip: ENABLED (nodes will be excluded from KMM deployment after success)"
fi
echo ""

read -p "Proceed with rolling update? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Process each worker node sequentially
CURRENT=0
FAILED_NODES=""
SUCCESSFUL_NODES=""

for node in $WORKER_NODES; do
    CURRENT=$((CURRENT + 1))
    
    print_header "Processing node $CURRENT/$NODE_COUNT: $node"
    
    # Check if other nodes are ready before proceeding
    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "1")
    
    if [ "$ready_nodes" -lt 2 ]; then
        print_warning "Only $ready_nodes node(s) ready. Waiting for cluster stability..."
        sleep 30
    fi
    
    # Run the prepare script
    if "$SCRIPT_DIR/prepare_node_for_vastnfs.sh" "$node" $EXTRA_ARGS; then
        print_success "Node $node prepared successfully"
        SUCCESSFUL_NODES="$SUCCESSFUL_NODES $node"
        
        # Ensure node is skipped by KMM deployment if requested
        if [ "$LABEL_SKIP" = "true" ]; then
            print_info "Ensuring node $node is skipped by KMM..."
            kubectl label node "$node" vastnfs-kmm/enabled- 2>/dev/null || true
            # Patch Module selector to require enabled=true (if Module exists)
            if kubectl get module vastnfs -n "${NAMESPACE:-vastnfs-kmm}" >/dev/null 2>&1; then
                kubectl patch module vastnfs -n "${NAMESPACE:-vastnfs-kmm}" --type=merge \
                    -p '{"spec":{"selector":{"vastnfs-kmm/enabled":"true"}}}' 2>/dev/null || true
            fi
            print_success "Node $node will be skipped by KMM"
        fi
        
        # Brief pause between nodes to let cluster stabilize
        if [ $CURRENT -lt $NODE_COUNT ]; then
            print_info "Waiting 30 seconds before next node..."
            sleep 30
        fi
    else
        print_error "Node $node preparation failed"
        FAILED_NODES="$FAILED_NODES $node"
        
        echo ""
        print_warning "Node $node failed. Options:"
        echo "  1. Continue with remaining nodes"
        echo "  2. Abort rolling update"
        echo ""
        read -p "Continue? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Aborting. Remember to uncordon failed node: kubectl uncordon $node"
            break
        fi
    fi
done

# Summary
print_header "Rolling Update Summary"

echo "Total nodes: $NODE_COUNT"
echo ""

if [ -n "$SUCCESSFUL_NODES" ]; then
    print_success "Successfully prepared:$SUCCESSFUL_NODES"
fi

if [ -n "$FAILED_NODES" ]; then
    print_error "Failed nodes:$FAILED_NODES"
    echo ""
    print_warning "Failed nodes may still be cordoned. Check with:"
    echo "  kubectl get nodes"
    echo ""
    print_warning "To uncordon: kubectl uncordon <node-name>"
fi

# Final status
echo ""
print_info "VAST NFS Status on all worker nodes:"
echo ""
printf "%-25s %-15s %-25s %-20s\n" "NODE" "STATUS" "OS" "VAST NFS"
printf "%-25s %-15s %-25s %-20s\n" "----" "------" "--" "--------"

for node in $WORKER_NODES; do
    status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    schedulable=$(kubectl get node "$node" -o jsonpath='{.spec.unschedulable}')
    os=$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null | cut -c1-25 || echo "Unknown")
    
    if [ "$schedulable" = "true" ]; then
        node_status="Cordoned"
    elif [ "$status" = "True" ]; then
        node_status="Ready"
    else
        node_status="NotReady"
    fi
    
    POD_NAME="status-$(echo "$node" | tr '.' '-' | cut -c1-15)-$$"
    version=$(kubectl run "$POD_NAME" -n "$NAMESPACE" --rm -i --restart=Never --image="$HELPER_IMAGE" \
        --overrides='{"spec":{"nodeName":"'"$node"'","hostPID":true,"containers":[{"name":"c","image":"'"$HELPER_IMAGE"'","command":["nsenter","-t","1","-m","-u","-i","-n","--","cat","/sys/module/sunrpc/parameters/nfs_bundle_version"],"securityContext":{"privileged":true}}],"tolerations":[{"operator":"Exists"}]}}' 2>/dev/null | grep -v "command prompt" | grep -v "^pod " | head -1 || echo "N/A")
    
    printf "%-25s %-15s %-25s %-20s\n" "$node" "$node_status" "$os" "$version"
done

echo ""
if [ -z "$FAILED_NODES" ]; then
    print_success "Rolling update completed successfully!"
    exit 0
else
    print_error "Rolling update completed with failures"
    exit 1
fi
