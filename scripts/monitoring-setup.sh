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

echo "📈 Enabling ingress-nginx metrics..."
bash "$(dirname "$0")/ingress-metrics-setup.sh"

# Each resources/dashboards/*.json becomes a ConfigMap the Grafana sidecar
# loads into the Homelab folder. Server-side apply: dashboards outgrow the
# 256KB last-applied annotation client-side apply would add.
echo "🖼️  Loading Grafana dashboards..."
for f in "$(dirname "$0")"/../resources/dashboards/*.json; do
  name="dashboard-$(basename "${f}" .json)"
  kubectl create configmap "${name}" -n monitoring --from-file="$(basename "${f}")=${f}" \
      --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml \
    | kubectl annotate --local -f - grafana_folder=Homelab -o yaml \
    | kubectl apply --server-side --force-conflicts -f - >/dev/null
  echo "   ${name}"
done

NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER_NAME:-homelab}-control-plane" 2>/dev/null || echo "<node-ip>")

echo ""
echo "✅ Monitoring stack installed!"
echo "   Grafana: http://${GRAFANA_HOST}  (admin / ${GRAFANA_PASSWORD})"
echo "   Add to /etc/hosts:  ${NODE_IP}  ${GRAFANA_HOST}"
echo ""
