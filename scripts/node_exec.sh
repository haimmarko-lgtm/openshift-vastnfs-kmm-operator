#!/usr/bin/env bash
# Abstraction over "run this shell snippet on a node, as root, with full host
# access" that works on both OpenShift (`oc debug node/<n> -- chroot /host`)
# and vanilla Kubernetes (`kubectl run` with an `nsenter -t 1 ...` overlay).
#
# Two usage styles:
#
#   1. Library mode (sourced by other scripts):
#        source scripts/node_exec.sh
#        node_exec "$node" 'cat /etc/os-release; lsmod | grep sunrpc'
#
#      The `node_exec` function prints the command's stdout on stdout and
#      propagates the exit code. Stderr is left alone (scripts can redirect).
#
#   2. CLI mode (standalone invocation):
#        scripts/node_exec.sh <node> '<shell command>'
#
# Environment variables:
#   PLATFORM          - openshift|vanilla (default: auto-detected)
#   KUBE_CMD          - kubectl|oc (default: kubectl if present, else oc)
#   HELPER_IMAGE      - image for nsenter pods on vanilla (default: alpine:latest)
#   NODE_EXEC_TIMEOUT - timeout in seconds for the pod (default: 120)
#
# The pod name is randomized so multiple invocations in parallel don't collide.

set -u

# -- helpers ------------------------------------------------------------------

_node_exec_detect_platform() {
    if [ -n "${PLATFORM:-}" ]; then
        echo "${PLATFORM}"
        return
    fi
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -x "${here}/detect_platform.sh" ]; then
        "${here}/detect_platform.sh"
    else
        echo "vanilla"
    fi
}

_node_exec_pick_kubectl() {
    if [ -n "${KUBE_CMD:-}" ]; then
        echo "${KUBE_CMD}"
        return
    fi
    if command -v kubectl >/dev/null 2>&1; then
        echo "kubectl"
    elif command -v oc >/dev/null 2>&1; then
        echo "oc"
    else
        echo "kubectl"  # best effort; caller will see the error
    fi
}

# -- main entrypoint ---------------------------------------------------------
#
# node_exec <node-name> <shell-command>
#
# Exit code:
#   - command's exit code on success path
#   - 2 if args are missing
node_exec() {
    local node="${1:-}"
    local cmd="${2:-}"
    if [ -z "${node}" ] || [ -z "${cmd}" ]; then
        echo "node_exec: usage: node_exec <node-name> <shell-command>" >&2
        return 2
    fi

    local platform
    platform="$(_node_exec_detect_platform)"
    local kube
    kube="$(_node_exec_pick_kubectl)"

    # Prefer `oc debug` when we're on OpenShift AND `oc` is on PATH -- it's
    # concise, well-known, and doesn't leave a pod behind on failure.
    if [ "${platform}" = "openshift" ] && command -v oc >/dev/null 2>&1; then
        oc debug "node/${node}" -- chroot /host bash -c "${cmd}"
        return $?
    fi

    # Otherwise spawn a privileged pod that nsenter's into PID 1.
    local helper_image="${HELPER_IMAGE:-alpine:latest}"
    local timeout="${NODE_EXEC_TIMEOUT:-120}"
    local pod="node-exec-$(echo "${node}" | tr '.' '-' | cut -c1-40)-$$-$RANDOM"

    local overrides
    overrides=$(cat <<EOF
{
  "apiVersion": "v1",
  "spec": {
    "nodeName": "${node}",
    "hostPID": true,
    "hostNetwork": true,
    "hostIPC": true,
    "restartPolicy": "Never",
    "tolerations": [{"operator": "Exists"}],
    "containers": [{
      "name": "node-exec",
      "image": "${helper_image}",
      "command": ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "bash", "-c", "${cmd//\"/\\\"}"],
      "securityContext": {"privileged": true},
      "stdin": false,
      "tty": false
    }]
  }
}
EOF
)

    "${kube}" run "${pod}" \
        --rm -i \
        --image="${helper_image}" \
        --restart=Never \
        --pod-running-timeout="${timeout}s" \
        --overrides="${overrides}" 2>/dev/null
    local rc=$?

    # Best-effort cleanup in case --rm didn't fire (e.g. cmd exited non-zero).
    "${kube}" delete pod "${pod}" --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
    return $rc
}

# -- CLI entry ---------------------------------------------------------------

# Only run as a CLI if this script is invoked directly (not sourced).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <node-name> <shell-command>" >&2
        exit 2
    fi
    node_exec "$1" "$2"
fi
