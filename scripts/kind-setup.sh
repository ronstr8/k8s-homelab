#!/bin/bash
# Kind cluster setup for local development (homelab)
# Supports logodal, poker, and moor projects.
# 
# Features:
# - Local Docker registry on port 5000
# - Nginx Ingress Controller on 80/443
# - cert-manager with shared ClusterIssuers
# - Generic hostPath storage support

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"

# Pin to a stable node image to avoid bleeding-edge API issues
NODE_IMAGE="kindest/node:v1.31.0"

# Storage path for persistent volumes on the host
STORAGE_PATH="${STORAGE_PATH:-${HOME}/.local/share/k8s-volumes}"

# Email for Let's Encrypt (ClusterIssuer) — required for letsencrypt-prod
: "${ACME_EMAIL:?ACME_EMAIL must be set (e.g. export ACME_EMAIL=you@example.com)}"

# Host user identity — PV directories will be chowned to these values
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"

# GPU
GPU_ENABLED="${GPU_ENABLED:-false}"
GPU_VENDOR="${GPU_VENDOR:-nvidia}"
NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.16.0}"

# Hermes
HERMES="${HERMES:-false}"
HERMES_DATA_PATH="${HERMES_DATA_PATH:-${HOME}/.hermes}"

# Ollama
OLLAMA="${OLLAMA:-false}"
OLLAMA_DATA_PATH="${OLLAMA_DATA_PATH:-${HOME}/.ollama}"

echo "🔧 ${CLUSTER_NAME} Kind Setup"
echo "======================"

# ── GPU Preflight ────────────────────────────────────────────────────────────
if [[ "${GPU_ENABLED}" == "true" ]]; then
  echo "🎮 GPU_ENABLED=true — checking prerequisites (vendor: ${GPU_VENDOR})..."

  if [[ "${GPU_VENDOR}" != "nvidia" ]]; then
    echo "⚠️  GPU_VENDOR=${GPU_VENDOR} is not yet supported. Only 'nvidia' is implemented."
    echo "   Continuing without GPU support."
    GPU_ENABLED="false"
  else
    _gpu_ok=true

    if command -v nvidia-smi &>/dev/null; then
      echo "   ✅ nvidia-smi found"
      nvidia-smi -L 2>/dev/null | sed 's/^/      /' || true
    else
      echo "   ⚠️  nvidia-smi not found — is the NVIDIA driver installed?"
      _gpu_ok=false
    fi

    if ! nvidia-container-cli --version &>/dev/null 2>&1; then
      echo "   ⚠️  nvidia-container-toolkit not found."
      echo "      Install: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
      _gpu_ok=false
    else
      echo "   ✅ nvidia-container-toolkit found"
    fi

    _docker_runtime=$(docker info --format '{{.DefaultRuntime}}' 2>/dev/null || echo "unknown")
    if [[ "${_docker_runtime}" != "nvidia" ]]; then
      echo "   ⚠️  Docker default runtime is '${_docker_runtime}', expected 'nvidia'."
      echo "      Add to /etc/docker/daemon.json and restart Docker:"
      echo '      {'
      echo '        "default-runtime": "nvidia",'
      echo '        "runtimes": {'
      echo '          "nvidia": { "path": "/usr/bin/nvidia-container-runtime", "runtimeArgs": [] }'
      echo '        }'
      echo '      }'
      _gpu_ok=false
    else
      echo "   ✅ Docker default runtime is nvidia"
    fi

    if [[ "${_gpu_ok}" == "false" ]]; then
      echo "   ❌ GPU prerequisites not met. Set GPU_ENABLED=false or fix the above."
      exit 1
    fi
  fi
fi

# ── 0. Prepare Generic Host Storage ──────────────────────────────────
echo "📂 Ensuring host storage root exists at ${STORAGE_PATH}..."
mkdir -p "${STORAGE_PATH}"

# ── 1. Local Registry ────────────────────────────────────────────────
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != 'true' ]; then
  echo "📦 Starting local Docker registry on localhost:${REGISTRY_PORT}..."
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" --network bridge --name "${REGISTRY_NAME}" registry:2
else
  echo "📦 Registry already running."
fi

# ── 2. Kind Cluster ──────────────────────────────────────────────────
echo "☸️  Checking cluster health..."
SHOULD_CREATE=true

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "   Cluster '${CLUSTER_NAME}' exists. Verifying API server..."
  # Try to connect to the cluster. If it fails, we assume it's broken.
  if kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    echo "   ✅ API server is responsive."
    SHOULD_CREATE=false
  else
    echo "   ⚠️  API server is unresponsive (EOF/Timeout). Deleting broken cluster..."
    kind delete cluster --name "${CLUSTER_NAME}"
  fi
fi

# Build optional GPU extraMount for the kind node.
# Requires Docker default-runtime=nvidia so the nvidia-container-runtime
# sees the /var/run/nvidia-container-devices/all sentinel and exposes all GPUs.
GPU_KIND_MOUNT=""
if [[ "${GPU_ENABLED}" == "true" ]]; then
  if [ "${SHOULD_CREATE}" = true ]; then
    GPU_KIND_MOUNT="      - hostPath: /dev/null
        containerPath: /var/run/nvidia-container-devices/all"
  else
    echo "   ⚠️  Cluster already exists — GPU device mount cannot be added retroactively."
    echo "      Run 'make recreate GPU_ENABLED=true' to rebuild with GPU passthrough."
  fi
fi

# Build optional Hermes data extraMount.
# Maps HERMES_DATA_PATH (~/.hermes) into the kind node at /mnt/hermes-data so
# pods can mount it as a hostPath volume without leaving the k8s-volumes subtree.
HERMES_KIND_MOUNT=""
if [[ "${HERMES}" == "true" ]]; then
  mkdir -p "${HERMES_DATA_PATH}"
  if [ "${SHOULD_CREATE}" = true ]; then
    HERMES_KIND_MOUNT="      - hostPath: ${HERMES_DATA_PATH}
        containerPath: /mnt/hermes-data"
  else
    echo "   ⚠️  Cluster already exists — Hermes data mount cannot be added retroactively."
    echo "      Option A: make recreate HERMES=true"
    echo "      Option B: ln -s ${HERMES_DATA_PATH} ${STORAGE_PATH}/hermes"
    echo "               then: make hermes HERMES_DATA_PATH=${STORAGE_PATH}/hermes"
  fi
fi

# Build optional Ollama data extraMount.
# Maps OLLAMA_DATA_PATH (~/.ollama by default) into the kind node at /mnt/ollama-data
# so the pod shares models with the host Ollama installation.
OLLAMA_KIND_MOUNT=""
if [[ "${OLLAMA}" == "true" ]]; then
  mkdir -p "${OLLAMA_DATA_PATH}"
  if [ "${SHOULD_CREATE}" = true ]; then
    OLLAMA_KIND_MOUNT="      - hostPath: ${OLLAMA_DATA_PATH}
        containerPath: /mnt/ollama-data"
  else
    echo "   ⚠️  Cluster already exists — Ollama data mount cannot be added retroactively."
    echo "      Option A: make recreate OLLAMA=true"
    echo "      Option B: ln -s ${OLLAMA_DATA_PATH} ${STORAGE_PATH}/ollama"
    echo "               then: make ollama OLLAMA_DATA_PATH=${STORAGE_PATH}/ollama"
  fi
fi

if [ "$SHOULD_CREATE" = true ]; then
  echo "☸️  Creating Kind cluster '${CLUSTER_NAME}' using image ${NODE_IMAGE}..."
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --image "${NODE_IMAGE}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ${STORAGE_PATH}
        containerPath: /mnt/k8s-volumes
${GPU_KIND_MOUNT}
${HERMES_KIND_MOUNT}
${OLLAMA_KIND_MOUNT}
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      - containerPort: 8888
        hostPort: 8888
        protocol: TCP
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        apiVersion: kubeadm.k8s.io/v1beta3
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
EOF
fi

# ── 3. Ensure kubectl context ───────────────────────────────────────
echo "🔌 Ensuring kubectl context is set for '${CLUSTER_NAME}'..."
kind export kubeconfig --name "${CLUSTER_NAME}"

# ── 3.5. Redirect local-path-provisioner → STORAGE_PATH ──────────────
# Kind ships local-path-provisioner defaulting to /var/local-path-provisioner
# (inside the node container, not on the host). Redirect it to /mnt/k8s-volumes
# so all dynamically provisioned PVCs land under STORAGE_PATH on the host.
echo "💾 Redirecting local-path-provisioner → ${STORAGE_PATH}..."
LPP_NS=""
for _ns in local-path-storage kube-system; do
  if kubectl get deployment local-path-provisioner -n "${_ns}" &>/dev/null 2>&1; then
    LPP_NS="${_ns}"
    break
  fi
done

if [[ -n "${LPP_NS}" ]]; then
  # Wait for provisioner to be ready before patching
  kubectl wait -n "${LPP_NS}" \
    --for=condition=available deployment/local-path-provisioner \
    --timeout=60s

  # Redirect provisioner to /mnt/k8s-volumes (= STORAGE_PATH on the host).
  # Only patch config.json — leave setup/teardown scripts at their defaults
  # to avoid helper pod issues with custom scripts.
  kubectl patch configmap local-path-config -n "${LPP_NS}" --type=merge \
    --patch '{"data":{"config.json":"{\"nodePathMap\":[{\"node\":\"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\"paths\":[\"/mnt/k8s-volumes\"]}]}"}}'

  kubectl rollout restart deployment/local-path-provisioner -n "${LPP_NS}"
  kubectl rollout status deployment/local-path-provisioner -n "${LPP_NS}" --timeout=60s
  echo "   ✅ Dynamic PVCs will provision under ${STORAGE_PATH}/ owned by UID ${HOST_UID}:${HOST_GID}"
else
  echo "   ⚠️  local-path-provisioner not found — dynamic PVCs will use Kind's default path."
fi

# ── 4. Connect Registry to Kind Network ──────────────────────────────
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}" 2>/dev/null)" = 'null' ] || \
   [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}" 2>/dev/null)" = '' ]; then
  echo "🔗 Connecting registry to Kind network..."
  docker network connect "kind" "${REGISTRY_NAME}" || true
else
  echo "🔗 Registry already on Kind network."
fi

# Modern containerd registry config (config_path approach)
echo "🔗 Configuring containerd nodes for local registry..."
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${REGISTRY_NAME}:5000"]
EOF
done

# Document the registry for Kind
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# ── 5. Ingress Controller (nginx) ────────────────────────────────────
echo "🌐 Deploying ingress-nginx controller..."
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION:-controller-v1.11.3}/deploy/static/provider/kind/deploy.yaml"

echo "⏳ Waiting for ingress-nginx to be ready..."
until kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; do sleep 1; done
kubectl wait --namespace ingress-nginx \
  --for=condition=available deployment/ingress-nginx-controller \
  --timeout=300s

echo "⏳ Waiting for ingress-nginx admission webhook to be ready..."
_webhook_ip=""
until [[ -n "${_webhook_ip}" ]]; do
  _webhook_ip=$(kubectl get endpoints ingress-nginx-controller-admission -n ingress-nginx \
    -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  sleep 2
done
# The admission webhook service maps :443 → pod:8443. Probe 8443 directly
# on the pod IP — port 443 on the same pod is for ingress traffic and is
# always open, so probing it gives a false positive.
_node=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
until docker exec "${_node}" bash -c \
  "timeout 2 bash -c 'echo >/dev/tcp/${_webhook_ip}/8443'" 2>/dev/null; do
  sleep 2
done

# ── 6. cert-manager ──────────────────────────────────────────────────
echo "🔐 Installing cert-manager..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION:-v1.14.2}/cert-manager.yaml"

echo "⏳ Waiting for cert-manager components to be ready..."
for dep in cert-manager cert-manager-cainjector cert-manager-webhook; do
  until kubectl get deployment "$dep" -n cert-manager >/dev/null 2>&1; do sleep 1; done
  kubectl wait --namespace cert-manager \
    --for=condition=available deployment/"$dep" \
    --timeout=300s
done

echo "⏳ Waiting for cert-manager webhook caBundle injection..."
until kubectl get validatingwebhookconfiguration cert-manager-webhook \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q '.'; do
  sleep 3
done

echo "📜 Applying shared ClusterIssuers (Email: ${ACME_EMAIL})..."
sed "s/^    email: .*/    email: ${ACME_EMAIL}/" resources/cluster-issuers.yaml | kubectl apply -f -

# ── 7. Patch Ingress for Moor (Port 8888) ────────────────────────────
echo "🛰️  Patching Ingress for Moor telnet (port 8888)..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: tcp-services
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: moor
    meta.helm.sh/release-namespace: moor
data:
  "8888": "moor/moor-telnet-host:8888"
EOF

# Patch the controller to pick up the tcp-services configmap
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--tcp-services-configmap=ingress-nginx/tcp-services"}]' 2>/dev/null || true

# Expose port 8888 on the controller pod
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --patch '{"spec":{"template":{"spec":{"containers":[{"name":"controller","ports":[{"containerPort":8888,"hostPort":8888,"protocol":"TCP"}]}]}}}}'

# Add 8888 to the controller service
kubectl patch svc ingress-nginx-controller \
  -n ingress-nginx \
  --patch '{"spec":{"ports":[{"name":"telnet","port":8888,"protocol":"TCP","targetPort":8888}]}}'

# ── 8. Discover cluster IP ───────────────────────────────────────────
NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER_NAME}-control-plane")

echo ""
echo "✅ Kind cluster '${CLUSTER_NAME}' is ready!"
echo "   Registry:  localhost:${REGISTRY_PORT}"
echo "   Cluster IP: ${NODE_IP}"
echo ""
echo "Add to /etc/hosts:"
echo "   ${NODE_IP} logodal.com"
echo "   ${NODE_IP} poker.fazigu.org"
echo "   ${NODE_IP} moor.fazigu.org"

# ── 9. GPU Device Plugin (optional) ─────────────────────────────────────────
if [[ "${GPU_ENABLED}" == "true" ]]; then
  echo "🎮 Deploying NVIDIA device plugin (${NVIDIA_DEVICE_PLUGIN_VERSION})..."
  kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"
  echo "   ✅ nvidia.com/gpu resource will be available on GPU-equipped nodes."
fi

# ── 10. Monitoring (optional) ────────────────────────────────────────────────
if [ "${MONITORING:-false}" = "true" ]; then
  bash "$(dirname "$0")/monitoring-setup.sh"
  echo "   ${NODE_IP} grafana.fazigu.org"
fi

# ── 11. Ollama (optional) ────────────────────────────────────────────────────
if [ "${OLLAMA:-false}" = "true" ]; then
  bash "$(dirname "$0")/ollama-setup.sh"
  if [[ -n "${OLLAMA_INGRESS_HOST:-}" ]]; then
    echo "   ${NODE_IP} ${OLLAMA_INGRESS_HOST}"
  fi
fi

# ── 12. Hermes (optional) ────────────────────────────────────────────────────
if [ "${HERMES:-false}" = "true" ]; then
  bash "$(dirname "$0")/hermes-setup.sh"
  if [[ -n "${HERMES_DASHBOARD_INGRESS_HOST:-}" ]]; then
    echo "   ${NODE_IP} ${HERMES_DASHBOARD_INGRESS_HOST}"
  fi
fi

echo ""
