#!/bin/bash
# Bring back a cluster suspended by cluster-pause.sh.
#
# Starts the node + registry containers, waits for the API server, re-verifies
# GPU passthrough if it was enabled, then restores every workload's replica
# count from the snapshot in reverse order (datastores → apps → ingress) so
# backends are up before anything routes traffic to them.
#
# Usage:  cluster-resume.sh

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
STORAGE_PATH="${STORAGE_PATH:-${HOME}/.local/share/k8s-volumes}"
PAUSE_STATE_DIR="${PAUSE_STATE_DIR:-${STORAGE_PATH}/.pause-state}"
PAUSE_LAST="${PAUSE_LAST:-}"
RESUME_TIMEOUT="${RESUME_TIMEOUT:-300}"

GPU_ENABLED="${GPU_ENABLED:-false}"
GPU_VENDOR="${GPU_VENDOR:-nvidia}"

STATE_FILE="${PAUSE_STATE_DIR}/workloads.tsv"

echo "▶️  ${CLUSTER_NAME} Cluster Resume"
echo "==========================="

if ! docker inspect "${CLUSTER_NAME}-control-plane" &>/dev/null; then
  echo "❌ Node container '${CLUSTER_NAME}-control-plane' does not exist."
  echo "   The cluster was deleted, not paused. Run: make up"
  exit 1
fi

# ── Start containers ────────────────────────────────────────────────────────
# Registry first so image pulls resolve the moment kubelet starts reconciling.
if docker inspect "${REGISTRY_NAME}" &>/dev/null; then
  echo "📦 Starting registry..."
  docker start "${REGISTRY_NAME}" >/dev/null
fi

echo "☸️  Starting node container..."
docker start "${CLUSTER_NAME}-control-plane" >/dev/null

# ── Node IP drift ───────────────────────────────────────────────────────────
# Docker reassigns the container IP on start. Certs have SANs that cover it, but
# /etc/hosts entries written by `make hosts` point at the old address, which
# breaks both browser access and cert-manager's HTTP-01 self-check.
NEW_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  "${CLUSTER_NAME}-control-plane" 2>/dev/null || true)
OLD_IP=$(cat "${PAUSE_STATE_DIR}/node-ip" 2>/dev/null || true)
IP_CHANGED=false
if [[ -n "${OLD_IP}" && -n "${NEW_IP}" && "${OLD_IP}" != "${NEW_IP}" ]]; then
  IP_CHANGED=true
  echo "   ⚠️  Node IP changed: ${OLD_IP} → ${NEW_IP}"
fi

# ── Wait for the API server ─────────────────────────────────────────────────
echo "⏳ Waiting for node to become Ready (timeout ${RESUME_TIMEOUT}s)..."
_deadline=$(( SECONDS + RESUME_TIMEOUT ))
until kubectl cluster-info --request-timeout=5s &>/dev/null 2>&1; do
  if (( SECONDS >= _deadline )); then
    echo "❌ API server did not come up within ${RESUME_TIMEOUT}s."
    echo "   Check: docker logs ${CLUSTER_NAME}-control-plane"
    exit 1
  fi
  sleep 3
done

kubectl wait --for=condition=Ready "node/${CLUSTER_NAME}-control-plane" \
  --timeout="${RESUME_TIMEOUT}s" >/dev/null
echo "   ✅ Node Ready"

# ── GPU re-verification ─────────────────────────────────────────────────────
# The nvidia runtime re-runs its injection hook on `docker start`, so the node
# normally picks the GPU back up on its own — including a swapped card. The
# device plugin, though, caches its device list from before the stop and needs a
# restart to re-advertise.
if [[ "${GPU_ENABLED}" == "true" && "${GPU_VENDOR}" == "nvidia" ]]; then
  echo "🎮 Verifying GPU passthrough..."
  nvidia-smi -L 2>/dev/null | sed 's/^/   /' || echo "   ⚠️  nvidia-smi unavailable on the host."

  _gpu_capacity() {
    kubectl get node "${CLUSTER_NAME}-control-plane" \
      -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || true
  }

  _cap="$(_gpu_capacity)"
  if [[ -z "${_cap}" || "${_cap}" == "0" ]]; then
    echo "   ↻ No nvidia.com/gpu advertised — restarting device plugin..."
    kubectl rollout restart -n kube-system daemonset/nvidia-device-plugin-daemonset >/dev/null 2>&1 || true
    kubectl rollout status -n kube-system daemonset/nvidia-device-plugin-daemonset \
      --timeout=120s >/dev/null 2>&1 || true

    _deadline=$(( SECONDS + 60 ))
    while (( SECONDS < _deadline )); do
      _cap="$(_gpu_capacity)"
      [[ -n "${_cap}" && "${_cap}" != "0" ]] && break
      sleep 3
    done
  fi

  if [[ -n "${_cap}" && "${_cap}" != "0" ]]; then
    echo "   ✅ Node advertising nvidia.com/gpu: ${_cap}"
  else
    echo "   ❌ Node is not advertising nvidia.com/gpu."
    echo "      GPU pods will sit Pending. The device mount is wired at cluster"
    echo "      creation time, so the fix is:  make recreate GPU_ENABLED=true"
    echo "      (host PV data and — with CERT_PERSIST=true — TLS certs survive,"
    echo "       but Helm releases must be reinstalled.)"
  fi
fi

# ── Restore workloads ───────────────────────────────────────────────────────
if [[ ! -f "${STATE_FILE}" ]]; then
  echo ""
  echo "⚠️  No pause snapshot at ${STATE_FILE} — workloads left as-is."
  echo "   The cluster is up; scale things back by hand or re-run your Helm installs."
  exit 0
fi

_restore() {
  local kind="$1" ns="$2" name="$3" replicas="$4"
  kubectl get "${kind}" -n "${ns}" "${name}" &>/dev/null || {
    echo "   ⚠️  ${ns}/${name} no longer exists — skipping."
    return 0
  }
  echo "   ↑ ${kind,,}/${ns}/${name} → ${replicas}"
  kubectl scale "${kind}" -n "${ns}" "${name}" --replicas="${replicas}" >/dev/null 2>&1 || true
}

# Tier 1: StatefulSets — datastores first, and wait, so apps find them ready.
echo "🗃️  Restoring StatefulSets..."
while IFS=$'\t' read -r kind ns name replicas; do
  [[ "${kind}" == "StatefulSet" ]] && _restore "${kind}" "${ns}" "${name}" "${replicas}"
done < "${STATE_FILE}"

while IFS=$'\t' read -r kind ns name replicas; do
  [[ "${kind}" != "StatefulSet" || "${replicas}" == "0" ]] && continue
  kubectl rollout status statefulset -n "${ns}" "${name}" --timeout="${RESUME_TIMEOUT}s" >/dev/null 2>&1 \
    || echo "   ⚠️  ${ns}/${name} not ready yet — continuing."
done < "${STATE_FILE}"

# Tier 2: PAUSE_LAST Deployments — the ones that own data, before their clients.
for ref in ${PAUSE_LAST}; do
  ns="${ref%%/*}"; name="${ref##*/}"
  _line=$(awk -F'\t' -v n="${ns}" -v d="${name}" \
    '$1=="Deployment" && $2==n && $3==d' "${STATE_FILE}" 2>/dev/null || true)
  [[ -z "${_line}" ]] && continue
  echo "🗄️  Restoring ${ref}..."
  IFS=$'\t' read -r kind _ns _name replicas <<< "${_line}"
  _restore Deployment "${ns}" "${name}" "${replicas}"
  kubectl rollout status deployment -n "${ns}" "${name}" --timeout="${RESUME_TIMEOUT}s" >/dev/null 2>&1 \
    || echo "   ⚠️  ${ref} not ready yet — continuing."
done

# Tier 3: application Deployments.
echo "📦 Restoring application workloads..."
while IFS=$'\t' read -r kind ns name replicas; do
  [[ "${kind}" != "Deployment" || "${ns}" == "ingress-nginx" ]] && continue
  _in_pause_last=false
  for ref in ${PAUSE_LAST}; do [[ "${ns}/${name}" == "${ref}" ]] && _in_pause_last=true; done
  [[ "${_in_pause_last}" == "true" ]] && continue
  _restore "${kind}" "${ns}" "${name}" "${replicas}"
done < "${STATE_FILE}"

# Tier 4: ingress — reopen the door last, once backends are serving.
echo "🚪 Reopening ingress..."
while IFS=$'\t' read -r kind ns name replicas; do
  [[ "${ns}" == "ingress-nginx" ]] && _restore "${kind}" "${ns}" "${name}" "${replicas}"
done < "${STATE_FILE}"

echo ""
echo "✅ Cluster resumed."
if [[ "${IP_CHANGED}" == "true" ]]; then
  echo ""
  echo "   ⚠️  The node IP changed (${OLD_IP} → ${NEW_IP}). /etc/hosts is stale."
  echo "      Run:  make hosts"
fi
echo "   Check state with: make status"
