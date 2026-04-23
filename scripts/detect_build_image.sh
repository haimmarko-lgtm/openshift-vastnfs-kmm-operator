#!/bin/bash
# Detect appropriate build image(s) based on cluster node OS
# 
# Note: With the multi-kernel-mapping Module CRD, BUILD_IMAGE selection
# is now automatic based on kernel version patterns. This script provides
# informational output and backward compatibility.

set -e

if ! command -v kubectl >/dev/null 2>&1; then
    echo "ubuntu:22.04"
    exit 0
fi

# Quick reachability probe: TCP-connect to the configured API server via `nc`
# (falling back to /dev/tcp) with a short wait. kubectl itself retries ~5x
# regardless of --request-timeout, so we bail out early if the API server is
# unreachable and this script is expanded via $(shell ...) in the Makefile.
_api_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
if [ -n "${_api_server}" ]; then
    _rest=${_api_server#*://}
    _hostport=${_rest%%/*}
    _host=${_hostport%:*}
    _port=${_hostport##*:}
    if [ "${_port}" = "${_hostport}" ]; then
        case "${_api_server}" in
            https://*) _port=443 ;;
            http://*)  _port=80  ;;
            *)         _port=443 ;;
        esac
    fi
    # Bounded TCP probe with a manual kill timer, since `nc -w` and bash's
    # /dev/tcp both fall back to the kernel's default connect() timeout on
    # many platforms. We spawn the probe in the background and reap/kill it
    # after ~2s.
    (
        if command -v nc >/dev/null 2>&1; then
            nc -z "${_host}" "${_port}" >/dev/null 2>&1
        else
            exec 3<>/dev/tcp/"${_host}"/"${_port}"
        fi
    ) &
    _probe_pid=$!
    for _ in 1 2 3 4; do
        kill -0 "${_probe_pid}" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "${_probe_pid}" 2>/dev/null; then
        kill -9 "${_probe_pid}" 2>/dev/null || true
        wait "${_probe_pid}" 2>/dev/null || true
        echo "ubuntu:22.04"
        exit 0
    fi
    if ! wait "${_probe_pid}" 2>/dev/null; then
        echo "ubuntu:22.04"
        exit 0
    fi
fi

# Get all unique OS images from cluster nodes.
# Use a short --request-timeout so the Makefile doesn't hang when this is
# expanded via $(shell ...) against an unreachable or misconfigured cluster.
NODE_INFO=$(kubectl get nodes --request-timeout=3s -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.osImage}{"\t"}{.status.nodeInfo.kernelVersion}{"\n"}{end}' 2>/dev/null)

if [ -z "$NODE_INFO" ]; then
    echo "ubuntu:22.04"
    exit 0
fi

# If called with --verbose or --info flag, show detailed information
if [ "$1" = "--verbose" ] || [ "$1" = "--info" ]; then
    echo "=== Cluster Node OS Detection ===" >&2
    echo "" >&2
    echo "Node Information:" >&2
    echo "$NODE_INFO" | while IFS=$'\t' read -r node os kernel; do
        echo "  $node:" >&2
        echo "    OS:     $os" >&2
        echo "    Kernel: $kernel" >&2
        
        # Determine build image for this kernel
        kernel_lower=$(echo "$kernel" | tr '[:upper:]' '[:lower:]')
        case "$kernel_lower" in
            *-generic|*-lowlatency|*-aws|*-azure|*-gcp|*-oracle)
                echo "    Build:  ubuntu:22.04 (Debian-family kernel)" >&2
                ;;
            *.el9*)
                echo "    Build:  rockylinux:9 (RHEL 9 family kernel)" >&2
                ;;
            *.el8*)
                echo "    Build:  rockylinux:8 (RHEL 8 family kernel)" >&2
                ;;
            *.fc[0-9]*)
                echo "    Build:  fedora:latest (Fedora kernel)" >&2
                ;;
            *-default)
                echo "    Build:  opensuse/leap (SUSE kernel)" >&2
                ;;
            *)
                echo "    Build:  ubuntu:22.04 (fallback)" >&2
                ;;
        esac
    done
    echo "" >&2
    
    # Check for mixed kernels
    KERNEL_TYPES=$(echo "$NODE_INFO" | while IFS=$'\t' read -r node os kernel; do
        kernel_lower=$(echo "$kernel" | tr '[:upper:]' '[:lower:]')
        case "$kernel_lower" in
            *-generic|*-lowlatency|*-aws|*-azure|*-gcp|*-oracle) echo "debian" ;;
            *.el9*) echo "rhel9" ;;
            *.el8*) echo "rhel8" ;;
            *.fc[0-9]*) echo "fedora" ;;
            *-default) echo "suse" ;;
            *) echo "unknown" ;;
        esac
    done | sort -u)
    
    UNIQUE_TYPES=$(echo "$KERNEL_TYPES" | wc -l)
    
    if [ "$UNIQUE_TYPES" -gt 1 ]; then
        echo "NOTE: Mixed kernel types detected in cluster:" >&2
        echo "$KERNEL_TYPES" | while read type; do
            echo "  - $type" >&2
        done
        echo "" >&2
        echo "The Module CRD has multiple kernelMappings configured to handle" >&2
        echo "each kernel type automatically with the appropriate build image." >&2
    else
        echo "Cluster has homogeneous kernel type: $(echo $KERNEL_TYPES | head -1)" >&2
    fi
    echo "" >&2
fi

# Return a single build image based on first node's kernel (for backward compatibility)
# The Module CRD handles per-kernel BUILD_IMAGE selection automatically
FIRST_KERNEL=$(echo "$NODE_INFO" | head -1 | cut -f3 | tr '[:upper:]' '[:lower:]')

case "$FIRST_KERNEL" in
    *-generic|*-lowlatency|*-aws|*-azure|*-gcp|*-oracle)
        echo "ubuntu:22.04"
        ;;
    *.el9*)
        echo "rockylinux:9"
        ;;
    *.el8*)
        echo "rockylinux:8"
        ;;
    *.fc[0-9]*)
        echo "fedora:latest"
        ;;
    *-default)
        echo "opensuse/leap"
        ;;
    *)
        echo "ubuntu:22.04"
        ;;
esac
