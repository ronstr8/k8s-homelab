#!/bin/bash
# Tear down the Kind cluster and registry.
# Optional namespaces are drained gracefully before the cluster is deleted so
# stateful workloads (Prometheus WAL, Hermes gateway connections, etc.) can
# shut down cleanly rather than receiving SIGKILL from docker rm -f.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
TEARDOWN_GRACE="${TEARDOWN_GRACE:-60}"   # seconds to wait for namespace drain

echo "🗑️  ${CLUSTER_NAME} Kind Teardown"
echo "========================="

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then

  # ── Save cert-manager TLS + ACME secrets before the cluster is destroyed ────
  if [[ "${CERT_PERSIST:-false}" == "true" ]]; then
    bash "$(dirname "$0")/cert-persist.sh" save || echo "⚠️  cert save failed (continuing teardown)."
  fi

  # ── Graceful drain of optional namespaces ──────────────────────────────────
  if kubectl cluster-info --request-timeout=5s &>/dev/null 2>&1; then
    for ns in monitoring ollama hermes; do
      if kubectl get namespace "${ns}" &>/dev/null 2>&1; then
        echo "⏳ Draining ${ns} (grace period ${TEARDOWN_GRACE}s)..."
        kubectl delete namespace "${ns}" \
          --grace-period="${TEARDOWN_GRACE}" \
          --timeout="${TEARDOWN_GRACE}s" 2>/dev/null || true
      fi
    done
  else
    echo "⚠️  API server unreachable — skipping graceful drain."
  fi

  # ── Delete cluster ─────────────────────────────────────────────────────────
  echo "☸️  Deleting Kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "☸️  Cluster '${CLUSTER_NAME}' not found."
fi

# ── Remove registry ─────────────────────────────────────────────────────────
# Remove whether it's running OR exited — a Docker/daemon restart leaves the
# container stopped, and a leftover exited container collides by name on the
# next `make up`. Data is preserved on the host bind-mount regardless.
if docker inspect "${REGISTRY_NAME}" &>/dev/null; then
  echo "📦 Removing registry (data preserved on host)..."
  if ! docker rm -f "${REGISTRY_NAME}"; then
    echo "⚠️  Could not remove ${REGISTRY_NAME} (often a stale snap/AppArmor confinement"
    echo "    state after a Docker restart). It's harmless — a Docker daemon restart"
    echo "    reconciles it, e.g. 'make setup-gpu' or 'sudo snap restart docker'."
    echo "    Continuing; data is preserved on the host bind-mount either way."
  fi
else
  echo "📦 Registry not present."
fi

echo ""
echo "✅ Teardown complete."
