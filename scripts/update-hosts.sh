#!/bin/bash
# Sync /etc/hosts entries for cluster hostnames to the current Kind node IP.
#
# Why the node IP and not 127.0.0.1: this host reaches the ingress either way
# (Kind publishes 80/443/8888 on 0.0.0.0), but the node IP keeps the name
# pointing at the cluster itself rather than at whatever else happens to be
# bound locally on those ports.
#
# ── One exception: this host's own name ──────────────────────────────────────
# A hostname in HOSTS that is also this machine's identity does NOT get the
# node IP — it gets the host's LAN IP. Reassigning the machine's own name to a
# container breaks everything that resolves the host by name and expects to
# find the host: `ssh -Y` with X11UseLocalhost=no hands the session
# DISPLAY=<fqdn>:10.0, and the X client then dials <node-ip>:6010, where sshd
# is not listening. Same class of breakage for any daemon that advertises
# itself by FQDN. The LAN IP satisfies both: sshd is on it, and so is the
# published ingress.
#
# Manages a marked block so re-running is idempotent and never touches your
# other /etc/hosts entries. Requires sudo (writes /etc/hosts).
#
# Hostnames come from HOSTS (space-separated) plus any enabled component
# ingress hosts. Override HOSTS in .env to match your projects.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"

# Domains your apps' ingresses serve — set HOSTS in .env (space-separated).
HOSTS="${HOSTS:-}"

# Append enabled optional-component ingress hosts if set
[[ -n "${OLLAMA_INGRESS_HOST:-}" ]] && HOSTS="${HOSTS} ${OLLAMA_INGRESS_HOST}"
[[ -n "${HERMES_DASHBOARD_INGRESS_HOST:-}" ]] && HOSTS="${HOSTS} ${HERMES_DASHBOARD_INGRESS_HOST}"
[[ "${MONITORING:-false}" == "true" ]] && HOSTS="${HOSTS} grafana.example.com"

NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  "${CLUSTER_NAME}-control-plane" 2>/dev/null || true)

if [[ -z "${NODE_IP}" ]]; then
  echo "❌ Could not find node IP for '${CLUSTER_NAME}-control-plane'. Is the cluster up?"
  exit 1
fi

# This host's own names, and the LAN address to give them (see the header).
_self_names=" $(hostname -f 2>/dev/null) $(hostname -s 2>/dev/null) $(hostname 2>/dev/null) "
LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null \
  | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')

# Address for one hostname: the node IP, unless the name is this host's own.
host_ip_for() {
  case "${_self_names}" in
    *" $1 "*) echo "${LAN_IP}" ;;
    *)        echo "${NODE_IP}" ;;
  esac
}

MARKER_BEGIN="# BEGIN k8s-homelab (${CLUSTER_NAME}) — managed by make hosts"
MARKER_END="# END k8s-homelab (${CLUSTER_NAME})"

echo "🛠️  Updating /etc/hosts → ${NODE_IP}"

# Build the new managed block
_block="${MARKER_BEGIN}"$'\n'
for h in ${HOSTS}; do
  _ip="$(host_ip_for "${h}")"
  if [[ -z "${_ip}" ]]; then
    # Own name, but no LAN address to point it at. Writing the node IP here
    # would hijack the machine's identity, so leave the name to real DNS.
    echo "   ⚠️  ${h} is this host's own name and no LAN IP was found — skipping."
    continue
  fi
  _block+="${_ip} ${h}"$'\n'
  if [[ "${_ip}" == "${NODE_IP}" ]]; then
    echo "   ${_ip} ${h}"
  else
    echo "   ${_ip} ${h}   (this host's own name → LAN IP, not the node)"
  fi
done
_block+="${MARKER_END}"

# Remove any existing managed block (for this cluster), then append the new one.
_tmp=$(mktemp)
sudo sed "/^# BEGIN k8s-homelab (${CLUSTER_NAME})/,/^# END k8s-homelab (${CLUSTER_NAME})/d" \
  /etc/hosts > "${_tmp}"
# Drop trailing blank lines, then append the block
printf '%s\n%s\n' "$(cat "${_tmp}")" "${_block}" | sudo tee /etc/hosts >/dev/null
rm -f "${_tmp}"

echo "✅ /etc/hosts updated."
