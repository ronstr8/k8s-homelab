#!/bin/bash
# Remove Ollama from the cluster.
# Model data on the host at STORAGE_PATH/ollama is preserved by default.

set -euo pipefail

OLLAMA_NAMESPACE="${OLLAMA_NAMESPACE:-ollama}"
GPU_ENABLED="${GPU_ENABLED:-false}"
NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.16.0}"
STORAGE_PATH="${STORAGE_PATH:-${HOME}/.local/share/k8s-volumes}"

echo "🗑️  Removing Ollama (namespace: ${OLLAMA_NAMESPACE})..."

kubectl delete namespace "${OLLAMA_NAMESPACE}" --ignore-not-found=true
kubectl delete pv ollama-models-pv --ignore-not-found=true

if [[ "${GPU_ENABLED}" == "true" ]]; then
  echo "🎮 Removing NVIDIA device plugin..."
  kubectl delete -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml" \
    --ignore-not-found=true 2>/dev/null || true
fi

echo "✅ Ollama removed."
echo "   Model cache preserved at: ${STORAGE_PATH}/ollama"
echo "   To also purge model data: rm -rf ${STORAGE_PATH}/ollama"
