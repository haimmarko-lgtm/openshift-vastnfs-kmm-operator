#!/usr/bin/env bash
#
# migrate_from_legacy.sh — re-label / re-annotate an existing VAST NFS KMM
# install so it aligns with the unified manifest layout introduced after the
# vanilla+openshift consolidation.
#
# The script is safe by default: without --apply it prints a dry-run plan
# describing exactly which objects would be re-labeled or re-annotated.
#
# Usage:
#   ./migrate_from_legacy.sh              # dry-run only
#   APPLY=true ./migrate_from_legacy.sh   # perform the migration
#   ALLOW_RELOAD=true APPLY=true ./migrate_from_legacy.sh
#       — also re-applies the Module manifest (may trigger a module reload)
#
# Inputs (env):
#   NAMESPACE          Target namespace (default: vastnfs-kmm).
#   VASTNFS_VERSION    Sets app.kubernetes.io/version annotation on objects.
#   KUBE_CMD           kubectl or oc (auto-picked by common.sh).
#   PLATFORM           Auto-detected unless explicitly set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

NAMESPACE=${NAMESPACE:-$DEFAULT_NAMESPACE}
VASTNFS_VERSION=${VASTNFS_VERSION:-}
APPLY=${APPLY:-false}
ALLOW_RELOAD=${ALLOW_RELOAD:-false}

print_header "VAST NFS KMM — Legacy Migration"

print_info "Namespace: $NAMESPACE"
print_info "Platform:  ${PLATFORM}"
print_info "KUBE_CMD:  ${KUBE_CMD}"
print_info "APPLY:     $APPLY"
print_info "ALLOW_RELOAD: $ALLOW_RELOAD"

if ! "${KUBE_CMD}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
    print_warning "Namespace $NAMESPACE does not exist — nothing to migrate."
    exit 0
fi

legacy_detected=false
if "${KUBE_CMD}" get module vastnfs -n "$NAMESPACE" >/dev/null 2>&1; then
    legacy_detected=true
fi

if [ "$legacy_detected" = "false" ]; then
    print_warning "No existing Module/vastnfs in $NAMESPACE. Nothing to migrate."
    exit 0
fi

echo ""
print_step "Planned changes (dry-run)"

OBJECTS=(
    "module/vastnfs"
    "configmap/vastnfs-kmm-build-dockerfile"
    "serviceaccount/vastnfs-kmm-sa"
)

for obj in "${OBJECTS[@]}"; do
    if "${KUBE_CMD}" get "$obj" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "  - ${NAMESPACE}/${obj}"
        echo "      label : app.kubernetes.io/name=vastnfs-kmm"
        echo "      label : app.kubernetes.io/component=kernel-module"
        if [ -n "$VASTNFS_VERSION" ]; then
            echo "      annot : app.kubernetes.io/version=${VASTNFS_VERSION}"
        fi
    fi
done

if [ "$ALLOW_RELOAD" = "true" ]; then
    echo "  - re-apply Module manifest from k8s/overlays/${PLATFORM}/base (may trigger a reload)"
fi

echo ""
if [ "$APPLY" != "true" ]; then
    print_info "Dry-run complete. Re-run with APPLY=true to execute."
    exit 0
fi

print_step "Applying migration"

for obj in "${OBJECTS[@]}"; do
    if "${KUBE_CMD}" get "$obj" -n "$NAMESPACE" >/dev/null 2>&1; then
        "${KUBE_CMD}" label "$obj" -n "$NAMESPACE" \
            app.kubernetes.io/name=vastnfs-kmm \
            app.kubernetes.io/component=kernel-module \
            --overwrite >/dev/null
        if [ -n "$VASTNFS_VERSION" ]; then
            "${KUBE_CMD}" annotate "$obj" -n "$NAMESPACE" \
                "app.kubernetes.io/version=${VASTNFS_VERSION}" \
                --overwrite >/dev/null
        fi
        print_success "  labeled/annotated: ${NAMESPACE}/${obj}"
    fi
done

# Cluster-scoped RBAC objects with the common label.
for crb in $("${KUBE_CMD}" get clusterrolebinding -l app.kubernetes.io/name=vastnfs-kmm -o name 2>/dev/null || true); do
    "${KUBE_CMD}" label "$crb" app.kubernetes.io/component=kernel-module --overwrite >/dev/null || true
    if [ -n "$VASTNFS_VERSION" ]; then
        "${KUBE_CMD}" annotate "$crb" "app.kubernetes.io/version=${VASTNFS_VERSION}" --overwrite >/dev/null || true
    fi
    print_success "  annotated: $crb"
done

if [ "$ALLOW_RELOAD" = "true" ]; then
    print_step "Re-applying unified manifest (ALLOW_RELOAD=true)"
    # Intentionally non-fatal — users may prefer to run `make install` instead.
    if [ -x "${SCRIPT_DIR}/install_and_follow_logs.sh" ]; then
        NAMESPACE="$NAMESPACE" KUBE_CMD="${KUBE_CMD}" PLATFORM="${PLATFORM}" \
            "${SCRIPT_DIR}/install_and_follow_logs.sh" || \
            print_warning "install_and_follow_logs.sh exited non-zero"
    else
        print_warning "install_and_follow_logs.sh not executable; skipping re-apply"
    fi
else
    print_info "Skipping Module re-apply (ALLOW_RELOAD=false)"
fi

echo ""
print_success "Migration complete."
