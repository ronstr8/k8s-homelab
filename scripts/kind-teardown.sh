#!/bin/bash
# Tear down the Kind cluster and registry.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"

echo "🗑️ ${CLUSTER_NAME} Kind Teardown"
echo "========================="

# Delete Kind cluster
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "☸️  Deleting Kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "☸️  Cluster '${CLUSTER_NAME}' not found."
fi

# Stop and remove registry container
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" = 'true' ]; then
  echo "📦 Stopping and removing registry container..."
  docker rm -f "${REGISTRY_NAME}"
else
  echo "📦 Registry not running."
fi

echo ""
echo "✅ Teardown complete."
