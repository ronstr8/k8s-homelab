#!/bin/bash
# Deploy Ollama (local LLM inference) into the Kind cluster.
# The pod pulls OLLAMA_MODEL at startup; subsequent restarts reuse the cached data.
#
# Variables (all have defaults; export or pass via make):
#   OLLAMA_MODEL, OLLAMA_CONTEXT_LENGTH, OLLAMA_NAMESPACE, OLLAMA_STORAGE, OLLAMA_KEEP_ALIVE
#   OLLAMA_CPU_REQ, OLLAMA_CPU_LIM, OLLAMA_MEM_REQ, OLLAMA_MEM_LIM
#   OLLAMA_GPU, OLLAMA_GPU_COUNT   -- request nvidia.com/gpu resource
#   OLLAMA_INGRESS_HOST            -- empty = ClusterIP only
#   GPU_ENABLED                    -- deploy NVIDIA device plugin
#   STORAGE_PATH                   -- host base path for PV

set -euo pipefail

OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-24h}"
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma3:12b}"
# Ollama defaults num_ctx to 2048 regardless of the model's trained max, so set
# the serving context explicitly. This is a server-wide ceiling shared by every
# client, and the KV cache it implies is allocated per loaded model -- 32K keeps
# gemma3:12b comfortably inside a 16GB card. Raise it only if you also have the
# VRAM; clients that need less should send a smaller per-request num_ctx.
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-32768}"
OLLAMA_NAMESPACE="${OLLAMA_NAMESPACE:-ollama}"
OLLAMA_STORAGE="${OLLAMA_STORAGE:-20Gi}"
OLLAMA_CPU_REQ="${OLLAMA_CPU_REQ:-2}"
OLLAMA_CPU_LIM="${OLLAMA_CPU_LIM:-4}"
OLLAMA_MEM_REQ="${OLLAMA_MEM_REQ:-4Gi}"
OLLAMA_MEM_LIM="${OLLAMA_MEM_LIM:-12Gi}"
OLLAMA_GPU="${OLLAMA_GPU:-false}"
OLLAMA_GPU_COUNT="${OLLAMA_GPU_COUNT:-1}"
OLLAMA_INGRESS_HOST="${OLLAMA_INGRESS_HOST:-}"
GPU_ENABLED="${GPU_ENABLED:-false}"
NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.16.0}"
STORAGE_PATH="${STORAGE_PATH:-${HOME}/.local/share/k8s-volumes}"
# Ollama data lives under the shared homelab storage root (its own subdir, per
# convention) rather than a bespoke host path. STORAGE_PATH is mounted into the
# node at /mnt/k8s-volumes, so no dedicated kind extraMount is required.
OLLAMA_DATA_SUBDIR="${OLLAMA_DATA_SUBDIR:-ollama}"
OLLAMA_DATA_PATH="${STORAGE_PATH}/${OLLAMA_DATA_SUBDIR}"
OLLAMA_NODE_PATH="/mnt/k8s-volumes/${OLLAMA_DATA_SUBDIR}"
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"

echo "🦙 Installing Ollama"
echo "   model:     ${OLLAMA_MODEL}"
echo "   context:   ${OLLAMA_CONTEXT_LENGTH}"
echo "   keepalive: ${OLLAMA_KEEP_ALIVE}"
echo "   namespace: ${OLLAMA_NAMESPACE}"
echo "   data:      ${OLLAMA_DATA_PATH}"
echo "   resources: cpu ${OLLAMA_CPU_REQ}-${OLLAMA_CPU_LIM}, mem ${OLLAMA_MEM_REQ}-${OLLAMA_MEM_LIM}"
[[ "${OLLAMA_GPU}" == "true" ]] && echo "   gpu:       ${OLLAMA_GPU_COUNT}x nvidia.com/gpu"
[[ -n "${OLLAMA_INGRESS_HOST}" ]] && echo "   ingress:   http://${OLLAMA_INGRESS_HOST}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
if ! kubectl cluster-info &>/dev/null; then
  echo "❌ Cannot reach cluster. Run 'make up' first."
  exit 1
fi

if [[ "${OLLAMA_GPU}" == "true" && "${GPU_ENABLED}" != "true" ]]; then
  echo "⚠️  OLLAMA_GPU=true but GPU_ENABLED=false."
  echo "   The pod will request nvidia.com/gpu but the device plugin may not be installed."
  echo "   Run with GPU_ENABLED=true or set OLLAMA_GPU=false."
fi

# ── NVIDIA device plugin (idempotent, only when GPU is cluster-level enabled) ─
if [[ "${GPU_ENABLED}" == "true" ]]; then
  echo "🎮 Ensuring NVIDIA device plugin is deployed..."
  kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"
fi

# ── Host data directory ───────────────────────────────────────────────────────
mkdir -p "${OLLAMA_DATA_PATH}"

# ── Build conditional YAML fragments ─────────────────────────────────────────

# GPU resource lines injected into requests/limits blocks
GPU_RESOURCE_LINE=""
if [[ "${OLLAMA_GPU}" == "true" ]]; then
  GPU_RESOURCE_LINE="              nvidia.com/gpu: \"${OLLAMA_GPU_COUNT}\""
fi

# Optional Ingress manifest (only when OLLAMA_INGRESS_HOST is set)
INGRESS_MANIFEST=""
if [[ -n "${OLLAMA_INGRESS_HOST}" ]]; then
  INGRESS_MANIFEST=$(cat <<INGRESS
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ollama
  namespace: ${OLLAMA_NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
  rules:
    - host: ${OLLAMA_INGRESS_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ollama
                port:
                  number: 11434
INGRESS
)
fi

# ── Apply manifests ───────────────────────────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${OLLAMA_NAMESPACE}
---
# PV pre-bound to the namespace PVC so it isn't claimed by other workloads
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ollama-models-pv
spec:
  capacity:
    storage: ${OLLAMA_STORAGE}
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: ${OLLAMA_NODE_PATH}
    type: DirectoryOrCreate
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef:
    namespace: ${OLLAMA_NAMESPACE}
    name: ollama-models
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models
  namespace: ${OLLAMA_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${OLLAMA_STORAGE}
  storageClassName: ""
  volumeName: ollama-models-pv
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: ${OLLAMA_NAMESPACE}
  labels:
    app: ollama
spec:
  replicas: 1
  # Recreate, not RollingUpdate: the pod holds an RWO PVC and (when OLLAMA_GPU is
  # set) the node's only nvidia.com/gpu. Under RollingUpdate the new pod waits
  # for a GPU the old pod won't release until the new one is Ready — a rollout
  # that deadlocks with the new pod Pending on "Insufficient nvidia.com/gpu".
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      # Run as the host user so model files on the host PV are user-owned.
      securityContext:
        runAsUser: ${HOST_UID}
        runAsGroup: ${HOST_GID}
        fsGroup: ${HOST_GID}
      initContainers:
        # Ensure the models directory is owned by HOST_UID before ollama starts.
        # Necessary when the directory was previously written as root.
        - name: chown-data
          image: busybox:1.36
          command: ["chown", "-R", "${HOST_UID}:${HOST_GID}", "/ollama"]
          volumeMounts:
            - name: models
              mountPath: /ollama
          securityContext:
            runAsUser: 0
      containers:
        - name: ollama
          image: ollama/ollama:0.30.10
          # Start server in background, wait for it, pull the configured model,
          # then foreground the server process. On restarts the model is already
          # cached in the PVC so the pull is a fast no-op.
          command: ["/bin/sh", "-c"]
          args:
            - |
              ollama serve &
              _pid=\$!
              echo "Waiting for Ollama server..."
              # Use the bundled ollama CLI for readiness — the image ships no curl/wget.
              until ollama list >/dev/null 2>&1; do sleep 2; done
              echo "Pulling model: ${OLLAMA_MODEL}"
              ollama pull ${OLLAMA_MODEL}
              echo "Model ready — server running (pid \$_pid)"
              wait \$_pid
          env:
            - name: OLLAMA_HOST
              value: "0.0.0.0"
            - name: OLLAMA_MODELS
              value: "/ollama/models"
            - name: OLLAMA_KEEP_ALIVE
              value: "${OLLAMA_KEEP_ALIVE}"
            - name: OLLAMA_CONTEXT_LENGTH
              value: "${OLLAMA_CONTEXT_LENGTH}"
          ports:
            - containerPort: 11434
              name: api
          resources:
            requests:
              cpu: "${OLLAMA_CPU_REQ}"
              memory: "${OLLAMA_MEM_REQ}"
${GPU_RESOURCE_LINE}
            limits:
              cpu: "${OLLAMA_CPU_LIM}"
              memory: "${OLLAMA_MEM_LIM}"
${GPU_RESOURCE_LINE}
          volumeMounts:
            - name: models
              mountPath: /ollama
          readinessProbe:
            httpGet:
              path: /
              port: 11434
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 30
          livenessProbe:
            httpGet:
              path: /
              port: 11434
            initialDelaySeconds: 60
            periodSeconds: 20
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ollama-models
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: ${OLLAMA_NAMESPACE}
  labels:
    app: ollama
spec:
  selector:
    app: ollama
  ports:
    - name: api
      protocol: TCP
      port: 11434
      targetPort: 11434
  type: ClusterIP
${INGRESS_MANIFEST}
EOF

echo ""
echo "✅ Ollama deployed!"
echo "   Model '${OLLAMA_MODEL}' will be pulled at pod startup."
echo "   In-cluster endpoint: http://ollama.${OLLAMA_NAMESPACE}.svc.cluster.local:11434"
if [[ -n "${OLLAMA_INGRESS_HOST}" ]]; then
  echo "   Ingress: http://${OLLAMA_INGRESS_HOST}"
else
  echo "   Port-forward: kubectl port-forward -n ${OLLAMA_NAMESPACE} svc/ollama 11434:11434"
fi
echo ""
echo "⏳ Watch pod startup: kubectl logs -n ${OLLAMA_NAMESPACE} -l app=ollama -f"
echo ""
