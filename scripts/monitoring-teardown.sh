#!/bin/bash
set -euo pipefail

echo "🗑️  Removing monitoring stack..."
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
kubectl delete namespace monitoring --ignore-not-found=true
echo "✅ Monitoring stack removed."
