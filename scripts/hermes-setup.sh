#!/bin/bash
# Deploy Hermes Agent (gateway + dashboard) into the Kind cluster.
#
# The container runs `gateway run` as CMD args through s6-overlay (ENTRYPOINT=/init)
# which remaps HERMES_UID/GID then starts the dashboard service on
# HERMES_DASHBOARD_PORT. Both share the same pod and the same data volume.
#
# The dashboard is ClusterIP only (port-forward access). No ingress is created —
# the dashboard exposes API keys and must not be publicly reachable.
#
# IMPORTANT — data mount:
#   HERMES_DATA_PATH (~/.hermes by default) must be bind-mounted into the kind
#   node before the cluster is created. If you ran `make up HERMES=true` (or
#   `make recreate HERMES=true`) the mount is already in place at /mnt/hermes-data
#   inside the node. If the cluster already existed without that mount, see the
#   symlink workaround printed by kind-setup.sh.
#
# Variables (all have defaults; export or pass via make):
#   HERMES_IMAGE, HERMES_NAMESPACE, HERMES_DATA_PATH
#   HERMES_UID, HERMES_GID          -- s6-overlay remaps the internal hermes user to these
#   HERMES_DASHBOARD                -- "true" activates the s6 dashboard service
#   HERMES_DASHBOARD_PORT           -- dashboard listen port (default 9119)
#   HERMES_CPU_REQ/LIM, HERMES_MEM_REQ/LIM

set -euo pipefail

HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:latest}"
HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
HERMES_DATA_PATH="${HERMES_DATA_PATH:-${HOME}/.hermes}"
HERMES_UID="${HERMES_UID:-$(id -u)}"
HERMES_GID="${HERMES_GID:-$(id -g)}"
HERMES_DASHBOARD="${HERMES_DASHBOARD:-true}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
HERMES_DASHBOARD_OAUTH_CLIENT_ID="${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}"
# Dashboard is ClusterIP/port-forward only. Bind loopback: the auth gate exempts
# loopback binds, and `kubectl port-forward` reaches the pod's 127.0.0.1. (The old
# HERMES_DASHBOARD_INSECURE flag no longer disables the gate.)
HERMES_DASHBOARD_HOST="${HERMES_DASHBOARD_HOST:-127.0.0.1}"
# api_server (port 8642) refuses to start without a key, supplied via env.
HERMES_API_SERVER_KEY="${HERMES_API_SERVER_KEY:-}"
HERMES_CPU_REQ="${HERMES_CPU_REQ:-500m}"
HERMES_CPU_LIM="${HERMES_CPU_LIM:-2}"
HERMES_MEM_REQ="${HERMES_MEM_REQ:-512Mi}"
HERMES_MEM_LIM="${HERMES_MEM_LIM:-2Gi}"

echo "🤖 Installing Hermes Agent"
echo "   image:     ${HERMES_IMAGE}"
echo "   namespace: ${HERMES_NAMESPACE}"
echo "   data:      ${HERMES_DATA_PATH} (as UID ${HERMES_UID}:${HERMES_GID})"
echo "   dashboard: ${HERMES_DASHBOARD} (port ${HERMES_DASHBOARD_PORT}, ClusterIP only)"

# ── Prerequisites ─────────────────────────────────────────────────────────────
if ! kubectl cluster-info &>/dev/null; then
  echo "❌ Cannot reach cluster. Run 'make up' first."
  exit 1
fi

if [[ ! -d "${HERMES_DATA_PATH}" ]]; then
  echo "⚠️  ${HERMES_DATA_PATH} does not exist on the host."
  echo "   Hermes will start with an empty config — run 'hermes setup' inside the pod or on the host first."
  mkdir -p "${HERMES_DATA_PATH}"
fi

# Verify the kind node has the data mount; warn if not.
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${NODE}" ]]; then
  if ! docker exec "${NODE}" test -d /mnt/hermes-data 2>/dev/null; then
    echo ""
    echo "⚠️  /mnt/hermes-data is not mounted on the kind node '${NODE}'."
    echo "   The pod will start with an empty /opt/data — your ~/.hermes data won't be visible."
    echo "   To fix, choose one option:"
    echo "     A) make recreate HERMES=true  (recreates cluster with the mount)"
    echo "     B) ln -s ${HERMES_DATA_PATH} \${STORAGE_PATH:-~/.local/share/k8s-volumes}/hermes"
    echo "        then: make hermes HERMES_DATA_PATH=\${STORAGE_PATH:-~/.local/share/k8s-volumes}/hermes"
    echo ""
  fi
fi

# ── Build conditional YAML fragments ─────────────────────────────────────────

# Readiness probe: TCP socket on dashboard port if dashboard is enabled,
# otherwise exec-check for the gateway process.
if [[ "${HERMES_DASHBOARD}" == "true" ]]; then
  # The dashboard binds loopback (the auth gate exempts loopback binds). A
  # kubelet tcpSocket probe hits the pod IP, not loopback, so check 127.0.0.1
  # from inside the container instead.
  READINESS_PROBE="readinessProbe:
            exec:
              command: [\"python3\", \"-c\", \"import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(s.connect_ex(('127.0.0.1', ${HERMES_DASHBOARD_PORT})))\"]
            initialDelaySeconds: 30
            periodSeconds: 15
            failureThreshold: 10"
else
  READINESS_PROBE="readinessProbe:
            exec:
              command: [\"pgrep\", \"-f\", \"hermes gateway run\"]
            initialDelaySeconds: 20
            periodSeconds: 15
            failureThreshold: 6"
fi

# Dashboard port in container spec (only when dashboard is enabled)
DASHBOARD_PORT_SPEC=""
if [[ "${HERMES_DASHBOARD}" == "true" ]]; then
  DASHBOARD_PORT_SPEC="- containerPort: ${HERMES_DASHBOARD_PORT}
              name: dashboard"
fi

# ── Apply manifests ───────────────────────────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${HERMES_NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes
  namespace: ${HERMES_NAMESPACE}
  labels:
    app: hermes
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hermes
  template:
    metadata:
      labels:
        app: hermes
    spec:
      # s6-overlay cont-init.d stage2-hook requires root at startup to remap
      # HERMES_UID/GID via usermod/groupmod, then drops privileges itself.
      # Do NOT set runAsNonRoot or runAsUser here.
      containers:
        - name: hermes
          image: ${HERMES_IMAGE}
          # Pass gateway run as CMD args so s6-overlay (the image ENTRYPOINT)
          # runs first for UID remapping; main-wrapper.sh routes to hermes gateway run.
          args: ["gateway", "run"]
          env:
            - name: HERMES_UID
              value: "${HERMES_UID}"
            - name: HERMES_GID
              value: "${HERMES_GID}"
            - name: HERMES_DASHBOARD
              value: "${HERMES_DASHBOARD}"
            - name: HERMES_DASHBOARD_HOST
              value: "${HERMES_DASHBOARD_HOST}"
            - name: HERMES_DASHBOARD_PORT
              value: "${HERMES_DASHBOARD_PORT}"
            - name: HERMES_DASHBOARD_OAUTH_CLIENT_ID
              value: "${HERMES_DASHBOARD_OAUTH_CLIENT_ID}"
            - name: API_SERVER_KEY
              value: "${HERMES_API_SERVER_KEY}"
            - name: HERMES_HOME
              value: "/opt/data"
          ports:
            ${DASHBOARD_PORT_SPEC}
          resources:
            requests:
              cpu: "${HERMES_CPU_REQ}"
              memory: "${HERMES_MEM_REQ}"
            limits:
              cpu: "${HERMES_CPU_LIM}"
              memory: "${HERMES_MEM_LIM}"
          volumeMounts:
            - name: hermes-data
              mountPath: /opt/data
          ${READINESS_PROBE}
          livenessProbe:
            exec:
              command: ["pgrep", "-f", "hermes gateway run"]
            initialDelaySeconds: 60
            periodSeconds: 30
            failureThreshold: 3
      volumes:
        - name: hermes-data
          hostPath:
            path: /mnt/hermes-data
            type: DirectoryOrCreate
EOF

# Dashboard service (only created when dashboard is enabled)
if [[ "${HERMES_DASHBOARD}" == "true" ]]; then
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: hermes-dashboard
  namespace: ${HERMES_NAMESPACE}
  labels:
    app: hermes
spec:
  selector:
    app: hermes
  ports:
    - name: dashboard
      protocol: TCP
      port: ${HERMES_DASHBOARD_PORT}
      targetPort: ${HERMES_DASHBOARD_PORT}
  type: ClusterIP
EOF
fi

echo ""
echo "✅ Hermes Agent deployed!"
if [[ "${HERMES_DASHBOARD}" == "true" ]]; then
  echo "   Dashboard: kubectl port-forward -n ${HERMES_NAMESPACE} svc/hermes-dashboard ${HERMES_DASHBOARD_PORT}:${HERMES_DASHBOARD_PORT}"
fi
echo ""
echo "⏳ Watch pod startup: kubectl logs -n ${HERMES_NAMESPACE} -l app=hermes -f"
echo "💡 In-cluster Ollama: set the model block in ${HERMES_DATA_PATH}/config.yaml to"
echo "     provider: openai, base_url: http://ollama.ollama.svc.cluster.local:11434/v1, default: <model>"
echo "     then: kubectl rollout restart deploy/hermes -n ${HERMES_NAMESPACE}"
echo ""
