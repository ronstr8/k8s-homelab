#!/bin/bash
# Install kube-prometheus-stack (Prometheus + Grafana + node-exporter + kube-state-metrics)
set -euo pipefail

GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-homelab}"
GRAFANA_HOST="${GRAFANA_INGRESS_HOST:-grafana.example.com}"

echo "📊 Installing monitoring stack (kube-prometheus-stack)..."

if ! command -v helm &>/dev/null; then
  echo "❌ helm is not installed."
  echo "   Install: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

VERSION_FLAG=""
[[ -n "${PROMETHEUS_CHART_VERSION:-}" ]] && VERSION_FLAG="--version ${PROMETHEUS_CHART_VERSION}"

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values resources/monitoring-values.yaml \
  --set grafana.adminPassword="${GRAFANA_PASSWORD}" \
  --set "grafana.ingress.hosts[0]=${GRAFANA_HOST}" \
  ${VERSION_FLAG} \
  --timeout 10m \
  --wait

NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER_NAME:-homelab}-control-plane" 2>/dev/null || echo "<node-ip>")

echo ""
echo "✅ Monitoring stack installed!"
echo "   Grafana: http://${GRAFANA_HOST}  (admin / ${GRAFANA_PASSWORD})"
echo "   Add to /etc/hosts:  ${NODE_IP}  ${GRAFANA_HOST}"
echo ""
