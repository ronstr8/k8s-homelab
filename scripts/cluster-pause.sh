#!/bin/bash
# Suspend the cluster without destroying it — for host maintenance (hardware
# swaps, kernel upgrades, moving the box).
#
# Why not `make down`: teardown deletes the Kind cluster, which wipes etcd and
# every Helm release with it. For maintenance you want the cluster back exactly
# as it was, so instead we quiesce the workloads top-down (ingress → apps →
# datastores), record their replica counts, and stop the node container. The
# node's Docker restart policy is `on-failure`, so a clean stop means it stays
# stopped across a host reboot until `make resume` starts it again.
#
# Host PV data under STORAGE_PATH and the registry bind-mount are untouched.
#
# Usage:  cluster-pause.sh
#         PAUSE_LAST="moor/moor-daemon" cluster-pause.sh

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
STORAGE_PATH="${STORAGE_PATH:-${HOME}/.local/share/k8s-volumes}"
PAUSE_STATE_DIR="${PAUSE_STATE_DIR:-${STORAGE_PATH}/.pause-state}"

# Seconds to wait for a workload's pods to fully terminate before moving to the
# next tier, and for `docker stop` to let systemd/containerd shut down inside
# the node.
PAUSE_GRACE="${PAUSE_GRACE:-120}"

# Namespaces whose workloads are left running — control plane and storage
# machinery that should keep working right up until the node container stops.
# ingress-nginx is deliberately NOT here: it's the traffic gate and goes first.
PAUSE_SKIP_NAMESPACES="${PAUSE_SKIP_NAMESPACES:-kube-system kube-public kube-node-lease local-path-storage cert-manager}"

# Deployments to drain on their own beat, after the rest of the app tier but
# before StatefulSets. For workloads that own a database in a Deployment (rather
# than a StatefulSet) and need an uncontended window to checkpoint on SIGTERM.
# Space-separated "namespace/name".
PAUSE_LAST="${PAUSE_LAST:-}"

echo "⏸️  ${CLUSTER_NAME} Cluster Pause"
echo "=========================="

if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "❌ Cluster '${CLUSTER_NAME}' not found — nothing to pause."
  exit 1
fi

if ! kubectl cluster-info --request-timeout=5s &>/dev/null 2>&1; then
  echo "⚠️  API server unreachable — skipping graceful drain."
  echo "   Stopping containers directly; workloads will not have checkpointed."
  SKIP_DRAIN=true
else
  SKIP_DRAIN=false
fi

_in_list() { local n="$1"; shift; for x in $*; do [[ "${n}" == "${x}" ]] && return 0; done; return 1; }

# Poll .status.replicas — it counts pods that still exist, including ones in
# Terminating, so it only empties once the pods are actually gone. `kubectl
# rollout status` returns as soon as the spec is observed and would race us.
_wait_drained() {
  local kind="$1" ns="$2" name="$3" deadline=$(( SECONDS + PAUSE_GRACE ))
  while (( SECONDS < deadline )); do
    local n
    n="$(kubectl get "${kind}" -n "${ns}" "${name}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
    [[ -z "${n}" || "${n}" == "0" ]] && return 0
    sleep 2
  done
  echo "      ⚠️  ${ns}/${name} still has pods after ${PAUSE_GRACE}s — continuing anyway."
}

_scale_zero() {
  local kind="$1" ns="$2" name="$3"
  echo "   ↓ ${kind,,}/${ns}/${name}"
  kubectl scale "${kind}" -n "${ns}" "${name}" --replicas=0 >/dev/null 2>&1 || true
}

if [[ "${SKIP_DRAIN}" == "false" ]]; then
  # ── Snapshot current replica counts ────────────────────────────────────────
  # Written before anything is scaled, so `make resume` can restore the cluster
  # to exactly the shape it had — including workloads already at 0.
  mkdir -p "${PAUSE_STATE_DIR}"
  STATE_FILE="${PAUSE_STATE_DIR}/workloads.tsv"

  kubectl get deploy,statefulset -A \
    -o jsonpath='{range .items[*]}{.kind}{"\t"}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.replicas}{"\n"}{end}' \
    | while IFS=$'\t' read -r kind ns name replicas; do
        [[ -z "${kind}" ]] && continue
        _in_list "${ns}" "${PAUSE_SKIP_NAMESPACES}" && continue
        printf '%s\t%s\t%s\t%s\n' "${kind}" "${ns}" "${name}" "${replicas:-0}"
      done > "${STATE_FILE}"

  _count=$(wc -l < "${STATE_FILE}")
  echo "💾 Recorded ${_count} workload(s) → ${STATE_FILE}"

  # Node IP is assigned by Docker at container start and can change across a
  # host reboot. Record it so resume can tell you whether /etc/hosts is stale.
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "${CLUSTER_NAME}-control-plane" > "${PAUSE_STATE_DIR}/node-ip" 2>/dev/null || true

  # ── Tier 1: ingress — close the door before touching anything behind it ────
  echo "🚪 Closing ingress..."
  while IFS=$'\t' read -r kind ns name replicas; do
    [[ "${ns}" == "ingress-nginx" ]] && _scale_zero "${kind}" "${ns}" "${name}"
  done < "${STATE_FILE}"

  # ── Tier 2: application Deployments ───────────────────────────────────────
  echo "📦 Draining application workloads..."
  while IFS=$'\t' read -r kind ns name replicas; do
    [[ "${kind}" != "Deployment" || "${ns}" == "ingress-nginx" ]] && continue
    _in_list "${ns}/${name}" "${PAUSE_LAST}" && continue
    _scale_zero "${kind}" "${ns}" "${name}"
  done < "${STATE_FILE}"

  # ── Tier 3: PAUSE_LAST Deployments, drained and waited on individually ────
  for ref in ${PAUSE_LAST}; do
    ns="${ref%%/*}"; name="${ref##*/}"
    if kubectl get deployment -n "${ns}" "${name}" &>/dev/null; then
      echo "🗄️  Draining ${ref} (waiting for checkpoint)..."
      _scale_zero Deployment "${ns}" "${name}"
      _wait_drained deployment "${ns}" "${name}"
    else
      echo "   ⚠️  PAUSE_LAST entry '${ref}' not found — skipping."
    fi
  done

  # ── Tier 4: StatefulSets — databases go down last, one at a time ──────────
  echo "🗃️  Draining StatefulSets..."
  while IFS=$'\t' read -r kind ns name replicas; do
    [[ "${kind}" != "StatefulSet" ]] && continue
    _scale_zero "${kind}" "${ns}" "${name}"
    _wait_drained statefulset "${ns}" "${name}"
  done < "${STATE_FILE}"
fi

# ── Stop the containers ─────────────────────────────────────────────────────
# `docker stop` sends SIGTERM to systemd inside the node, which stops kubelet
# and containerd cleanly; -t gives that the same budget as the drain.
echo "🛑 Stopping containers (grace ${PAUSE_GRACE}s)..."
docker stop -t "${PAUSE_GRACE}" "${CLUSTER_NAME}-control-plane" >/dev/null
echo "   ✅ ${CLUSTER_NAME}-control-plane stopped"

if docker inspect "${REGISTRY_NAME}" &>/dev/null; then
  docker stop -t 30 "${REGISTRY_NAME}" >/dev/null 2>&1 || true
  echo "   ✅ ${REGISTRY_NAME} stopped"
fi

echo ""
echo "✅ Cluster paused. Safe to power off the host."
echo "   PV data is intact at ${STORAGE_PATH}"
echo "   Bring it back with: make resume"
echo ""
echo "   ℹ️  Pause does not back up databases. If this is hardware work, take a"
echo "      dump of anything irreplaceable before powering down."
