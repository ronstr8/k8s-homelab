#!/bin/bash
# Remove Hermes Agent from the cluster.
# Data at HERMES_DATA_PATH (~/.hermes) is never touched.

set -euo pipefail

HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"

echo "🗑️  Removing Hermes Agent (namespace: ${HERMES_NAMESPACE})..."

kubectl delete namespace "${HERMES_NAMESPACE}" --ignore-not-found=true

echo "✅ Hermes removed."
echo "   Data at ${HERMES_DATA_PATH:-~/.hermes} was not touched."
