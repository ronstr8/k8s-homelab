#!/bin/bash
# Deploy Hermes Agent (gateway + dashboard) into the Kind cluster.
#
# The container runs `gateway run` as its main process. When HERMES_DASHBOARD=true,
# the s6-overlay supervision tree also starts the dashboard service on
# HERMES_DASHBOARD_PORT. Both share the same pod and the same data volume.
#
# IMPORTANT — data mount:
#   HERMES_DATA_PATH (~/.hermes by default) must be bind-mounted into the kind
#   node before the cluster is created. If you ran `make up HERMES=true` (or
#   `make recreate HERMES=true`) the mount is already in place at /mnt/hermes-data
#   inside the node. If the cluster already existed without that mount, see the
#   symlink workaround printed by kind-setup.sh.
#
# IMPORTANT — security:
#   The dashboard exposes API keys. HERMES_DASHBOARD_INGRESS_HOST should only be
#   set for trusted-network hostnames. Default is ClusterIP (port-forward only).
#
# Variables (all have defaults; export or pass via make):
#   HERMES_IMAGE, HERMES_NAMESPACE, HERMES_DATA_PATH
#   HERMES_UID, HERMES_GID          -- s6-overlay remaps the internal hermes user to these
#   HERMES_DASHBOARD                -- "true" activates the s6 dashboard service
#   HERMES_DASHBOARD_PORT           -- dashboard listen port (default 9119)
#   HERMES_DASHBOARD_INGRESS_HOST   -- hostname for optional nginx Ingress
#   HERMES_CPU_REQ/LIM, HERMES_MEM_REQ/LIM

set -euo pipefail

HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:latest}"
HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
HERMES_DATA_PATH="${HERMES_DATA_PATH:-${HOME}/.hermes}"
HERMES_UID="${HERMES_UID:-$(id -u)}"
HERMES_GID="${HERMES_GID:-$(id -g)}"
HERMES_DASHBOARD="${HERMES_DASHBOARD:-true}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
HERMES_DASHBOARD_INGRESS_HOST="${HERMES_DASHBOARD_INGRESS_HOST:-}"
# ClusterIssuer for the dashboard TLS cert. Empty = no TLS (plain HTTP / nginx
# fake cert). Set to selfsigned-issuer, letsencrypt-staging, or letsencrypt-prod.
# letsencrypt-* require the host to be publicly reachable for the HTTP-01 challenge.
HERMES_DASHBOARD_CLUSTER_ISSUER="${HERMES_DASHBOARD_CLUSTER_ISSUER:-}"
HERMES_DASHBOARD_OAUTH_CLIENT_ID="${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}"
HERMES_CPU_REQ="${HERMES_CPU_REQ:-500m}"
HERMES_CPU_LIM="${HERMES_CPU_LIM:-2}"
HERMES_MEM_REQ="${HERMES_MEM_REQ:-512Mi}"
HERMES_MEM_LIM="${HERMES_MEM_LIM:-2Gi}"

echo "🤖 Installing Hermes Agent"
echo "   image:     ${HERMES_IMAGE}"
echo "   namespace: ${HERMES_NAMESPACE}"
echo "   data:      ${HERMES_DATA_PATH} (as UID ${HERMES_UID}:${HERMES_GID})"
echo "   dashboard: ${HERMES_DASHBOARD} (port ${HERMES_DASHBOARD_PORT})"
[[ -n "${HERMES_DASHBOARD_INGRESS_HOST}" ]] && echo "   ingress:   http://${HERMES_DASHBOARD_INGRESS_HOST}"

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
  READINESS_PROBE="readinessProbe:
            tcpSocket:
              port: ${HERMES_DASHBOARD_PORT}
            initialDelaySeconds: 30
            periodSeconds: 15
            failureThreshold: 10"
else
  READINESS_PROBE="readinessProbe:
            exec:
              command: [\"pgrep\", \"-f\", \"gateway run\"]
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

# Optional Ingress for the dashboard.
# When HERMES_DASHBOARD_CLUSTER_ISSUER is set, add the cert-manager annotation
# and a TLS block so cert-manager issues a cert into hermes-dashboard-tls.
INGRESS_MANIFEST=""
if [[ -n "${HERMES_DASHBOARD_INGRESS_HOST}" && "${HERMES_DASHBOARD}" == "true" ]]; then
  _issuer_annotation=""
  _tls_block=""
  if [[ -n "${HERMES_DASHBOARD_CLUSTER_ISSUER}" ]]; then
    _issuer_annotation="    cert-manager.io/cluster-issuer: ${HERMES_DASHBOARD_CLUSTER_ISSUER}"
    _tls_block="  tls:
    - hosts:
        - ${HERMES_DASHBOARD_INGRESS_HOST}
      secretName: hermes-dashboard-tls"
  fi
  INGRESS_MANIFEST=$(cat <<INGRESS
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hermes-dashboard
  namespace: ${HERMES_NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
${_issuer_annotation}
spec:
  ingressClassName: nginx
${_tls_block}
  rules:
    - host: ${HERMES_DASHBOARD_INGRESS_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hermes-dashboard
                port:
                  number: ${HERMES_DASHBOARD_PORT}
INGRESS
)
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
          # gateway run is the main process; s6-overlay supervises the dashboard
          # service in the background when HERMES_DASHBOARD=true.
          command: ["gateway", "run"]
          env:
            - name: HERMES_UID
              value: "${HERMES_UID}"
            - name: HERMES_GID
              value: "${HERMES_GID}"
            - name: HERMES_DASHBOARD
              value: "${HERMES_DASHBOARD}"
            - name: HERMES_DASHBOARD_HOST
              value: "0.0.0.0"
            - name: HERMES_DASHBOARD_PORT
              value: "${HERMES_DASHBOARD_PORT}"
            - name: HERMES_DASHBOARD_OAUTH_CLIENT_ID
              value: "${HERMES_DASHBOARD_OAUTH_CLIENT_ID}"
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
              command: ["pgrep", "-f", "gateway run"]
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

if [[ -n "${INGRESS_MANIFEST}" ]]; then
  echo "${INGRESS_MANIFEST}" | kubectl apply -f -
fi

echo ""
echo "✅ Hermes Agent deployed!"
if [[ "${HERMES_DASHBOARD}" == "true" ]]; then
  echo "   Dashboard port-forward: kubectl port-forward -n ${HERMES_NAMESPACE} svc/hermes-dashboard ${HERMES_DASHBOARD_PORT}:${HERMES_DASHBOARD_PORT}"
  [[ -n "${HERMES_DASHBOARD_INGRESS_HOST}" ]] && echo "   Dashboard ingress: http://${HERMES_DASHBOARD_INGRESS_HOST}"
  echo "   ⚠️  Dashboard exposes API keys — do not expose publicly without authentication."
fi
echo ""
echo "⏳ Watch pod startup: kubectl logs -n ${HERMES_NAMESPACE} -l app=hermes -f"
echo "💡 In-cluster Ollama: export OLLAMA_URL=http://ollama.ollama.svc.cluster.local:11434 in ~/.hermes/.env"
echo ""
