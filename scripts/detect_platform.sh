#!/usr/bin/env bash
# Detect whether the currently-targeted cluster is OpenShift or vanilla Kubernetes.
#
# Usage:
#   PLATFORM=$(scripts/detect_platform.sh)
#
# Prints one of: openshift | vanilla
#
# Detection order:
#   1. Explicit override via $PLATFORM env var (always wins).
#   2. Offline override: if OFFLINE=true (or the cluster is unreachable),
#      prefer whichever CLI is available -- `oc` implies openshift.
#   3. Probe the cluster: the presence of the `security.openshift.io` or
#      `image.openshift.io` API groups means OpenShift; otherwise vanilla.
#
# This script is intentionally quiet on stdout (only prints the final answer)
# so it is safe to use in $(shell ...) contexts from the Makefile.

set -u

# 1. Explicit override
if [ -n "${PLATFORM:-}" ]; then
    case "${PLATFORM}" in
        openshift|vanilla)
            echo "${PLATFORM}"
            exit 0
            ;;
        *)
            echo "vanilla"  # unknown value: fall back to safe default
            exit 0
            ;;
    esac
fi

# Pick a k8s CLI for probing
KUBE_CMD="${KUBE_CMD:-}"
if [ -z "${KUBE_CMD}" ]; then
    if command -v kubectl >/dev/null 2>&1; then
        KUBE_CMD="kubectl"
    elif command -v oc >/dev/null 2>&1; then
        KUBE_CMD="oc"
    fi
fi

# 2. Offline / no CLI: best-effort guess from which CLI is installed
if [ -z "${KUBE_CMD}" ] || [ "${OFFLINE:-false}" = "true" ]; then
    if command -v oc >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
        echo "openshift"
    else
        echo "vanilla"
    fi
    exit 0
fi

# 2b. Cheap TCP reachability probe -- kubectl's discovery retries ~5x and
# ignores --request-timeout for connection setup, so we short-circuit via a
# raw TCP connect against the API server. Bail out to the CLI heuristic when
# the cluster is offline, so this script never hangs the Makefile.
_api_server=$("${KUBE_CMD}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
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
        if command -v oc >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
            echo "openshift"
        else
            echo "vanilla"
        fi
        exit 0
    fi
    if ! wait "${_probe_pid}" 2>/dev/null; then
        if command -v oc >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
            echo "openshift"
        else
            echo "vanilla"
        fi
        exit 0
    fi
fi

# 3. Probe API groups -- quick timeout so this never hangs the Makefile
if "${KUBE_CMD}" api-resources --api-group=security.openshift.io \
        --request-timeout=3s --no-headers 2>/dev/null | grep -q securitycontextconstraints; then
    echo "openshift"
    exit 0
fi

if "${KUBE_CMD}" api-resources --api-group=image.openshift.io \
        --request-timeout=3s --no-headers 2>/dev/null | grep -q imagestream; then
    echo "openshift"
    exit 0
fi

# Cluster unreachable? Fall back to CLI heuristic.
if ! "${KUBE_CMD}" version --request-timeout=3s >/dev/null 2>&1; then
    if command -v oc >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
        echo "openshift"
    else
        echo "vanilla"
    fi
    exit 0
fi

echo "vanilla"
