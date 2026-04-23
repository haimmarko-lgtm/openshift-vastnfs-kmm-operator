#!/bin/bash
#
# Force clear VAST NFS images from registry and node caches
# This script is used by 'make build-only FORCE=true'
#

set -e

KMM_IMG_REPO="${1}"
VASTNFS_VERSION="${2}"
HELPER_IMAGE="${3:-alpine:latest}"
NAMESPACE="${NAMESPACE:-vastnfs-kmm}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Extract registry host and repository from KMM_IMG_REPO
# Format: registry:port/repository or registry/repository
parse_registry() {
    local img_repo="$1"
    
    # Check if it contains a port (colon followed by digits)
    if [[ "$img_repo" =~ ^([^/]+):([0-9]+)/(.+)$ ]]; then
        REGISTRY_HOST="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
        REPOSITORY="${BASH_REMATCH[3]}"
    elif [[ "$img_repo" =~ ^([^/]+)/(.+)$ ]]; then
        REGISTRY_HOST="${BASH_REMATCH[1]}"
        REPOSITORY="${BASH_REMATCH[2]}"
    else
        log_error "Could not parse registry from: $img_repo"
        return 1
    fi
}

# Delete images from registry using HTTP API
clear_registry_images() {
    log_info "Attempting to delete images from registry..."
    
    parse_registry "$KMM_IMG_REPO" || return 1
    
    log_info "Registry: $REGISTRY_HOST"
    log_info "Repository: $REPOSITORY"
    
    # Try to list tags matching our version
    local tags_url="http://${REGISTRY_HOST}/v2/${REPOSITORY}/tags/list"
    log_info "Fetching tags from: $tags_url"
    
    local tags_response
    tags_response=$(curl -s --connect-timeout 5 "$tags_url" 2>/dev/null) || {
        log_warning "Could not connect to registry API (may require HTTPS or authentication)"
        return 1
    }
    
    # Check if we got a valid response
    if ! echo "$tags_response" | grep -q '"tags"'; then
        log_warning "Could not list tags from registry (response: $tags_response)"
        return 1
    fi
    
    # Extract tags that match our version pattern
    local matching_tags
    matching_tags=$(echo "$tags_response" | grep -oE '"[^"]*-vastnfs-'"${VASTNFS_VERSION}"'"' | tr -d '"' || true)
    
    if [ -z "$matching_tags" ]; then
        log_info "No existing tags found matching version ${VASTNFS_VERSION}"
        return 0
    fi
    
    log_info "Found tags to delete:"
    echo "$matching_tags" | while read -r tag; do
        echo "  - $tag"
    done
    
    # Delete each tag
    echo "$matching_tags" | while read -r tag; do
        if [ -n "$tag" ]; then
            log_info "Deleting tag: $tag"
            
            # Try multiple manifest types to get the digest
            local manifest_url="http://${REGISTRY_HOST}/v2/${REPOSITORY}/manifests/${tag}"
            local digest=""
            
            # Try OCI manifest first
            digest=$(curl -s -I \
                -H "Accept: application/vnd.oci.image.manifest.v1+json" \
                -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
                -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
                "$manifest_url" 2>/dev/null | grep -i "Docker-Content-Digest:" | awk '{print $2}' | tr -d '\r\n') || true
            
            if [ -z "$digest" ]; then
                # Try without any specific Accept header
                digest=$(curl -s -I "$manifest_url" 2>/dev/null | grep -i "Docker-Content-Digest:" | awk '{print $2}' | tr -d '\r\n') || true
            fi
            
            if [ -n "$digest" ] && [ "$digest" != "" ]; then
                log_info "  Found digest: $digest"
                # Delete by digest
                local delete_url="http://${REGISTRY_HOST}/v2/${REPOSITORY}/manifests/${digest}"
                local delete_result
                delete_result=$(curl -s -X DELETE "$delete_url" -w "%{http_code}" -o /dev/null 2>/dev/null) || true
                
                if [ "$delete_result" = "202" ] || [ "$delete_result" = "200" ]; then
                    log_success "Deleted: $tag"
                else
                    log_warning "Could not delete $tag (HTTP $delete_result)"
                    log_info "  Registry may not support deletion or may need REGISTRY_STORAGE_DELETE_ENABLED=true"
                fi
            else
                log_warning "Could not get digest for $tag"
                log_info "  This is common with some registry configurations"
            fi
        fi
    done
    
    log_info "Registry cleanup complete"
    log_info "Note: If deletion failed, the registry may need REGISTRY_STORAGE_DELETE_ENABLED=true"
}

# Clear cached images from all nodes using crictl
clear_node_caches() {
    log_info "Clearing cached images from cluster nodes..."
    
    # Get all nodes
    local nodes
    nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
    
    if [ -z "$nodes" ]; then
        log_warning "No nodes found in cluster"
        return 1
    fi
    
    log_info "Found nodes: $nodes"
    log_info "Removing vastnfs images matching version: ${VASTNFS_VERSION}"
    log_info "Using namespace: ${NAMESPACE}"
    
    for node in $nodes; do
        log_info "Clearing cache on node: $node"
        
        local pod_name="clear-cache-$(echo "$node" | tr '.' '-' | cut -c1-20)-$$"
        
        # Use kubectl run with host access (in the configured namespace)
        local output
        output=$(kubectl run "$pod_name" -n "$NAMESPACE" --rm -i --restart=Never \
            --image="$HELPER_IMAGE" \
            --overrides='{
                "spec": {
                    "nodeName": "'"$node"'",
                    "hostPID": true,
                    "containers": [{
                        "name": "clear-cache",
                        "image": "'"$HELPER_IMAGE"'",
                        "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "sh", "-c", 
                            "echo \"Checking for container runtime on host...\"; if command -v crictl >/dev/null 2>&1; then echo \"Using crictl\"; echo \"Current vastnfs images:\"; crictl images 2>/dev/null | grep -i vastnfs || echo \"  (none found)\"; echo \"Removing vastnfs-'"${VASTNFS_VERSION}"' images only...\"; crictl images 2>/dev/null | grep \"vastnfs-'"${VASTNFS_VERSION}"'\" | awk \"{print \\$3}\" | while read img; do if [ -n \"$img\" ]; then echo \"  Removing image ID: $img\"; crictl rmi \"$img\" 2>/dev/null || echo \"    (failed or already removed)\"; fi; done; echo \"Removed vastnfs images (not pruning other images)\"; elif command -v ctr >/dev/null 2>&1; then echo \"Using ctr (containerd)\"; for ns in k8s.io default; do echo \"Checking namespace: $ns\"; ctr -n $ns images ls 2>/dev/null | grep \"vastnfs-'"${VASTNFS_VERSION}"'\" | awk \"{print \\$1}\" | while read img; do if [ -n \"$img\" ]; then echo \"  Removing: $img\"; ctr -n $ns images rm \"$img\" 2>/dev/null || echo \"    (failed or already removed)\"; fi; done; done; elif command -v nerdctl >/dev/null 2>&1; then echo \"Using nerdctl\"; nerdctl images 2>/dev/null | grep \"vastnfs-'"${VASTNFS_VERSION}"'\" | awk \"{print \\$3}\" | while read img; do if [ -n \"$img\" ]; then echo \"  Removing: $img\"; nerdctl rmi \"$img\" 2>/dev/null || true; fi; done; else echo \"No supported container runtime CLI found (crictl/ctr/nerdctl)\"; fi; echo \"Done\""
                        ],
                        "securityContext": {"privileged": true}
                    }],
                    "tolerations": [{"operator": "Exists"}]
                }
            }' 2>&1) || {
            log_warning "Could not run cleanup pod on $node (may need permissions)"
            # Try to cleanup in case pod was created
            kubectl delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found --force --grace-period=0 2>/dev/null || true
            continue
        }
        
        echo "$output" | grep -v "^pod " || true
        
        log_success "Cache operation completed on $node"
    done
    
    log_info "Node cache cleanup complete"
}

# Main execution
echo ""
echo "================================================================="
echo "  Force Clearing VAST NFS Images"
echo "================================================================="
echo ""

# Step 1: Try to clear registry images
REGISTRY_DELETE_FAILED=false
clear_registry_images || REGISTRY_DELETE_FAILED=true

echo ""

# Step 2: Clear node caches
clear_node_caches

echo ""
if [ "$REGISTRY_DELETE_FAILED" = "true" ]; then
    log_warning "Registry deletion failed - images still exist in registry"
    echo ""
    echo "To enable registry deletion, configure your registry with:"
    echo "  REGISTRY_STORAGE_DELETE_ENABLED=true"
    echo ""
    echo "Alternative: Use a different VASTNFS_VERSION to force new builds:"
    echo "  make build-only VASTNFS_VERSION=4.5.5-rebuild1 ..."
    echo ""
    log_info "Node caches were cleared - this helps with deployment but won't force rebuild"
else
    log_success "Force clear complete - builds will now be triggered"
fi
echo ""
