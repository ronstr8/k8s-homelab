#!/bin/bash
# Kind cluster setup for local development (homelab)
# Supports wordwank, poker, and moor projects.
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

echo "🔧 ${CLUSTER_NAME} Kind Setup"
echo "======================"

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
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "⏳ Waiting for ingress-nginx to be ready..."
# Wait for the deployment to exist first
until kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; do sleep 1; done
kubectl wait --namespace ingress-nginx \
  --for=condition=available deployment/ingress-nginx-controller \
  --timeout=300s

# ── 6. cert-manager ──────────────────────────────────────────────────
echo "🔐 Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.2/cert-manager.yaml

echo "⏳ Waiting for cert-manager components to be ready..."
for dep in cert-manager cert-manager-cainjector cert-manager-webhook; do
  until kubectl get deployment "$dep" -n cert-manager >/dev/null 2>&1; do sleep 1; done
  kubectl wait --namespace cert-manager \
    --for=condition=available deployment/"$dep" \
    --timeout=300s
done

echo "⏳ Giving cert-manager webhook 20s to stabilize..."
sleep 20

echo "📜 Applying shared ClusterIssuers (Email: ${ACME_EMAIL})..."
sed "s/email: .*/email: ${ACME_EMAIL}/" resources/cluster-issuers.yaml | kubectl apply -f -

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
echo "Common domain mappings (add to /etc/hosts):"
echo "   ${NODE_IP} wordwonk.fazigu.org"
echo "   ${NODE_IP} poker.fazigu.org"
echo "   ${NODE_IP} moor.fazigu.org"
echo ""
