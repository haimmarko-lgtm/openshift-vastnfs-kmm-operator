#!/bin/bash
#
# Build-only monitor script for VAST NFS KMM
# This script monitors build pods and prevents worker pods from deploying modules
#

NAMESPACE="${1:-vastnfs-kmm}"
VASTNFS_VERSION="${2:-}"
KMM_IMG_REPO="${3:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to delete worker pods
kill_workers() {
    local workers
    workers=$(kubectl get pods -n "$NAMESPACE" -l kmm.node.kubernetes.io/module.name=vastnfs,kmm.node.kubernetes.io/worker-action=Load -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -n "$workers" ]; then
        log_warning "Deleting worker pods to prevent deployment: $workers"
        kubectl delete pods -n "$NAMESPACE" -l kmm.node.kubernetes.io/module.name=vastnfs,kmm.node.kubernetes.io/worker-action=Load --force --grace-period=0 2>/dev/null || true
    fi
}

# Function to check if all builds completed
check_builds_complete() {
    local build_pods
    build_pods=$(kubectl get pods -n "$NAMESPACE" -l kmm.node.kubernetes.io/module.name=vastnfs,kmm.node.kubernetes.io/resource-type=BuildImage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$build_pods" ]; then
        return 0  # No build pods means either builds done or images already existed
    fi
    
    # Check if any build pod is still running or pending
    local running
    running=$(kubectl get pods -n "$NAMESPACE" -l kmm.node.kubernetes.io/module.name=vastnfs,kmm.node.kubernetes.io/resource-type=BuildImage --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -n "$running" ]; then
        return 1  # Builds still in progress
    fi
    
    return 0  # All builds complete
}

# Function to get build pod status
get_build_status() {
    kubectl get pods -n "$NAMESPACE" -l kmm.node.kubernetes.io/module.name=vastnfs,kmm.node.kubernetes.io/resource-type=BuildImage -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STARTED:.status.startTime" --no-headers 2>/dev/null
}

# Function to check ModuleImagesConfig for image status
check_image_status() {
    kubectl get moduleimagesconfig vastnfs -n "$NAMESPACE" -o jsonpath='{range .status.imagesStates[*]}{.image}: {.status}{"\n"}{end}' 2>/dev/null
}

# Function to show log commands for build pods
show_log_commands() {
    local build_pods
    build_pods=$(kubectl get pods -n "$NAMESPACE" -l kmm.node.kubernetes.io/module.name=vastnfs,kmm.node.kubernetes.io/resource-type=BuildImage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -n "$build_pods" ]; then
        echo ""
        log_info "To view build logs, run:"
        for pod in $build_pods; do
            echo "  kubectl logs -f $pod -n $NAMESPACE"
        done
        echo ""
    fi
}

# Main monitoring loop
log_info "Starting build-only monitor..."
echo ""

# First, quickly check if images already exist (most common case when re-running)
sleep 3  # Give KMM a moment to create ModuleImagesConfig
image_status=$(check_image_status)

if [ -n "$image_status" ]; then
    # Images exist - check if ALL images have status "Exists"
    all_exist=true
    needs_build=false
    
    while IFS= read -r line; do
        if echo "$line" | grep -q "NeedsBuild"; then
            needs_build=true
            all_exist=false
        elif ! echo "$line" | grep -q "Exists"; then
            all_exist=false
        fi
    done <<< "$image_status"
    
    if [ "$all_exist" = true ] && [ "$needs_build" = false ]; then
        log_success "All images already exist in registry - no build needed!"
        echo ""
        echo "$image_status"
        echo ""
        
        # Cleanup and exit - no builds needed
        log_info "Cleaning up Module (images are ready, preventing deployment)..."
        kubectl patch module vastnfs -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete module vastnfs -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true
        kill_workers
        
        echo ""
        echo "================================================================="
        echo "  Build-Only Complete (Images Already Existed)"
        echo "================================================================="
        echo ""
        log_info "Images are ready in: $KMM_IMG_REPO"
        echo ""
        log_info "To deploy to nodes later, you have two options:"
        echo ""
        echo "  Option 1: Gradual rollout with node preparation (recommended for production)"
        echo "            make prepare-worker NODE=<node-name> VASTNFS_VERSION=$VASTNFS_VERSION KMM_IMG_REPO=$KMM_IMG_REPO"
        echo ""
        echo "  Option 2: Full cluster deployment"
        echo "            make install VASTNFS_VERSION=$VASTNFS_VERSION KMM_IMG_REPO=$KMM_IMG_REPO"
        echo ""
        exit 0
    fi
fi

log_info "Monitoring for build pods (will prevent worker deployment)..."
echo ""

# Track if we've seen any build pods
seen_build_pods=false
build_started=false
max_wait_for_build=30  # seconds to wait for builds to start
wait_count=0
build_pods_list=""

while true; do
    # Kill any worker pods immediately
    kill_workers
    
    # Check for build pods
    build_status=$(get_build_status)
    
    if [ -n "$build_status" ]; then
        if [ "$build_started" = false ]; then
            log_success "Build pod(s) started:"
            echo "$build_status"
            build_started=true
            seen_build_pods=true
            
            # Store build pod names
            build_pods_list=$(kubectl get pods -n "$NAMESPACE" -l kmm.node.kubernetes.io/module.name=vastnfs,kmm.node.kubernetes.io/resource-type=BuildImage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
            
            # Show log commands instead of following logs
            show_log_commands
            
            log_info "Waiting for builds to complete..."
        fi
    else
        wait_count=$((wait_count + 1))
        
        if [ $wait_count -ge $max_wait_for_build ] && [ "$seen_build_pods" = false ]; then
            log_info "No build pods started. Checking if images already exist..."
            echo ""
            
            image_status=$(check_image_status)
            if [ -n "$image_status" ]; then
                log_success "Images already exist in registry:"
                echo "$image_status"
            else
                log_warning "No ModuleImagesConfig status found. KMM may still be processing."
            fi
            break
        fi
    fi
    
    # Check if builds are complete
    if [ "$build_started" = true ] && check_builds_complete; then
        echo ""
        log_info "Build(s) completed. Checking final status..."
        
        # Show final pod status
        echo ""
        kubectl get pods -n "$NAMESPACE" -l kmm.node.kubernetes.io/module.name=vastnfs,kmm.node.kubernetes.io/resource-type=BuildImage -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STARTED:.status.startTime" --no-headers 2>/dev/null
        echo ""
        
        # Check for any failed builds
        failed_builds=$(kubectl get pods -n "$NAMESPACE" -l kmm.node.kubernetes.io/module.name=vastnfs,kmm.node.kubernetes.io/resource-type=BuildImage --field-selector=status.phase=Failed -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        
        if [ -n "$failed_builds" ]; then
            log_error "Some builds failed: $failed_builds"
            echo ""
            log_info "To view failed build logs (if still available):"
            for pod in $failed_builds; do
                echo "  kubectl logs $pod -n $NAMESPACE"
            done
            echo ""
            
            log_info "Cleaning up Module..."
            kubectl patch module vastnfs -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            kubectl delete module vastnfs -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true
            exit 1
        fi
        
        log_success "All builds completed successfully!"
        echo ""
        
        # Show image status
        image_status=$(check_image_status)
        if [ -n "$image_status" ]; then
            log_info "Built images:"
            echo "$image_status"
            echo ""
        fi
        
        # Show log commands for reference
        if [ -n "$build_pods_list" ]; then
            log_info "To view build logs:"
            for pod in $build_pods_list; do
                echo "  kubectl logs $pod -n $NAMESPACE"
            done
            echo ""
        fi
        
        break
    fi
    
    sleep 2
done

# Final cleanup - delete the Module to prevent any future deployment attempts
log_info "Cleaning up Module to prevent deployment..."
kubectl patch module vastnfs -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete module vastnfs -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true

# Kill any remaining worker pods
kubectl delete pods -n "$NAMESPACE" -l kmm.node.kubernetes.io/module.name=vastnfs,kmm.node.kubernetes.io/worker-action=Load --force --grace-period=0 2>/dev/null || true

echo ""
echo "================================================================="
echo "  Build-Only Complete"
echo "================================================================="
echo ""
log_info "Images have been built and pushed to: $KMM_IMG_REPO"
echo ""
log_info "To deploy to nodes, choose one of these options:"
echo ""
echo "  Option 1: Single node deployment (recommended for production)"
echo "            Cordons, drains, unloads in-tree NFS, and deploys VAST NFS"
echo "            make prepare-worker NODE=<node-name> VASTNFS_VERSION=$VASTNFS_VERSION KMM_IMG_REPO=$KMM_IMG_REPO"
echo ""
echo "  Option 2: All nodes rolling deployment"
echo "            Processes all worker nodes one at a time"
echo "            make prepare-workers VASTNFS_VERSION=$VASTNFS_VERSION KMM_IMG_REPO=$KMM_IMG_REPO"
echo ""
echo "  Option 3: Direct deployment (for fresh clusters without NFS in use)"
echo "            make install VASTNFS_VERSION=$VASTNFS_VERSION KMM_IMG_REPO=$KMM_IMG_REPO"
echo ""
