#!/bin/bash
# Sync /etc/hosts entries for cluster hostnames to the current Kind node IP.
#
# Why the node IP and not 127.0.0.1: cert-manager's HTTP-01 self-check runs
# inside the cluster and resolves these names via the host's /etc/hosts (through
# Docker's embedded DNS). It must reach the ingress on the node, so the names
# have to point at the node IP, not the pod's own loopback.
#
# Manages a marked block so re-running is idempotent and never touches your
# other /etc/hosts entries. Requires sudo (writes /etc/hosts).
#
# Hostnames come from HOSTS (space-separated) plus any enabled component
# ingress hosts. Override HOSTS in .env to match your projects.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"

# Default project + component hostnames. Override via HOSTS in .env.
HOSTS="${HOSTS:-logodal.com poker.fazigu.org moor.fazigu.org}"

# Append enabled optional-component ingress hosts if set
[[ -n "${OLLAMA_INGRESS_HOST:-}" ]] && HOSTS="${HOSTS} ${OLLAMA_INGRESS_HOST}"
[[ -n "${HERMES_DASHBOARD_INGRESS_HOST:-}" ]] && HOSTS="${HOSTS} ${HERMES_DASHBOARD_INGRESS_HOST}"
[[ "${MONITORING:-false}" == "true" ]] && HOSTS="${HOSTS} grafana.fazigu.org"

NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  "${CLUSTER_NAME}-control-plane" 2>/dev/null || true)

if [[ -z "${NODE_IP}" ]]; then
  echo "❌ Could not find node IP for '${CLUSTER_NAME}-control-plane'. Is the cluster up?"
  exit 1
fi

MARKER_BEGIN="# BEGIN k8s-homelab (${CLUSTER_NAME}) — managed by make hosts"
MARKER_END="# END k8s-homelab (${CLUSTER_NAME})"

# Build the new managed block
_block="${MARKER_BEGIN}"$'\n'
for h in ${HOSTS}; do
  _block+="${NODE_IP} ${h}"$'\n'
done
_block+="${MARKER_END}"

echo "🛠️  Updating /etc/hosts → ${NODE_IP}"
for h in ${HOSTS}; do echo "   ${NODE_IP} ${h}"; done

# Remove any existing managed block (for this cluster), then append the new one.
_tmp=$(mktemp)
sudo sed "/^# BEGIN k8s-homelab (${CLUSTER_NAME})/,/^# END k8s-homelab (${CLUSTER_NAME})/d" \
  /etc/hosts > "${_tmp}"
# Drop trailing blank lines, then append the block
printf '%s\n%s\n' "$(cat "${_tmp}")" "${_block}" | sudo tee /etc/hosts >/dev/null
rm -f "${_tmp}"

echo "✅ /etc/hosts updated."
