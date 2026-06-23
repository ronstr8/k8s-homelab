#!/bin/bash
# One-time NVIDIA host configuration for running GPU workloads in the Kind cluster.
#
# This is the thing nobody should have to remember. It makes the host's Docker —
# whether the native (apt) daemon or the Canonical snap — ready for kind GPU
# passthrough by setting BOTH pieces the device plugin needs:
#
#   1. default-runtime = nvidia              (so the kind node is built with GPU access)
#   2. accept-nvidia-visible-devices-as-volume-mounts = true
#                                            (so the node's /var/run/nvidia-container-devices/all
#                                             mount injects the driver + NVML, not just /dev nodes)
#
# The trap it papers over: snap Docker ignores /etc/docker/daemon.json AND
# /etc/nvidia-container-runtime/config.toml — it reads its own copies under
# /var/snap/docker/current/. Each Docker snap refresh resets those, so re-run
# this after a snap update if the GPU stops being detected.
#
# Usage:  make setup-gpu      (re-execs itself with sudo)
set -euo pipefail

# ── Re-exec as root ──────────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
  echo "🔐 GPU host setup needs root — re-running with sudo..."
  exec sudo --preserve-env=PATH bash "$0" "$@"
fi

echo "🎮 NVIDIA host setup for Kind GPU passthrough"
echo "============================================="

# ── Prerequisites ────────────────────────────────────────────────────────────
if ! command -v nvidia-smi &>/dev/null; then
  echo "❌ nvidia-smi not found — install the NVIDIA driver first." >&2
  exit 1
fi
if ! command -v nvidia-ctk &>/dev/null; then
  echo "❌ nvidia-ctk not found — install nvidia-container-toolkit first:" >&2
  echo "   https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html" >&2
  exit 1
fi
echo "   ✅ nvidia driver + container toolkit present"

# ── Refuse to run with a live cluster (a Docker restart would strand proxies) ─
if docker ps --filter "label=io.x-k8s.kind.cluster" -q 2>/dev/null | grep -q .; then
  echo "❌ A Kind cluster is running. Restarting Docker now would strand its" >&2
  echo "   docker-proxy port holders (80/443/8888/5000). Tear down first:" >&2
  echo "       make down && make setup-gpu && make up" >&2
  exit 1
fi

# ── Detect Docker flavor and pick the config paths it actually reads ─────────
DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo '')"
if [[ "${DOCKER_ROOT}" == /var/snap/docker/* ]] || snap list docker &>/dev/null; then
  FLAVOR="snap"
  DAEMON_CONFIG="/var/snap/docker/current/config/daemon.json"
  RT_CONFIG="/var/snap/docker/current/etc/nvidia-container-runtime/config.toml"
  # The snap dockerd is confined; the nvidia runtime it can reach lives inside
  # the snap's current revision, not /usr/bin. Resolve the revision dynamically
  # so this keeps working across snap refreshes.
  SNAP_REV="$(readlink /snap/docker/current 2>/dev/null || echo current)"
  NVIDIA_RT_PATH="/snap/docker/${SNAP_REV}/usr/bin/nvidia-container-runtime"
  RESTART_CMD=(snap restart docker)
else
  FLAVOR="native"
  DAEMON_CONFIG="/etc/docker/daemon.json"
  RT_CONFIG="/etc/nvidia-container-runtime/config.toml"
  NVIDIA_RT_PATH="/usr/bin/nvidia-container-runtime"
  RESTART_CMD=(systemctl restart docker)
fi
echo "   📦 Docker flavor: ${FLAVOR}"
echo "      daemon config:  ${DAEMON_CONFIG}"
echo "      runtime config: ${RT_CONFIG}"

# ── 1. default-runtime = nvidia ──────────────────────────────────────────────
nvidia-ctk runtime configure \
  --runtime=docker \
  --config="${DAEMON_CONFIG}" \
  --nvidia-runtime-path="${NVIDIA_RT_PATH}" \
  --set-as-default
echo "   ✅ default-runtime set to nvidia in ${DAEMON_CONFIG}"

# ── 2. accept GPU volume-mount requests (injects driver + NVML into the node) ─
# This is the setting the kind node's /var/run/nvidia-container-devices/all mount
# needs. HOW we persist it differs by flavor:
if [[ "${FLAVOR}" == "snap" ]]; then
  # Snap Docker regenerates ${RT_CONFIG} on every start via its
  # nvidia-container-toolkit oneshot service, so a plain file edit is wiped on the
  # next restart. The generator instead writes whatever is in the snap setting
  # `nvidia-support.runtime.config-override` verbatim — that survives restarts AND
  # snap refreshes. Base the override on the snap's current generated config (to
  # keep its CDI defaults) and append our flag.
  _base="$(cat "${RT_CONFIG}" 2>/dev/null || true)"
  _override="$(printf '%s\n' "${_base}" \
    | grep -vE '^[[:space:]]*#?[[:space:]]*accept-nvidia-visible-devices-as-volume-mounts')"
  _override="${_override}"$'\n'"accept-nvidia-visible-devices-as-volume-mounts = true"
  snap set docker nvidia-support.runtime.config-override="${_override}"
  echo "   ✅ persisted volume-mount flag via 'snap set docker nvidia-support.runtime.config-override'"
else
  nvidia-ctk config --in-place \
    --set accept-nvidia-visible-devices-as-volume-mounts=true \
    --config-file="${RT_CONFIG}"
  echo "   ✅ accept-nvidia-visible-devices-as-volume-mounts=true in ${RT_CONFIG}"
fi

# ── 3. Restart Docker so both take effect ────────────────────────────────────
echo "   🔄 Restarting Docker (${RESTART_CMD[*]})..."
"${RESTART_CMD[@]}"

# Give the daemon a moment to come back before we query it.
for _ in $(seq 1 15); do
  docker info &>/dev/null && break
  sleep 1
done

# ── Verify (both settings, post-restart — this is the real test) ─────────────
_rt="$(docker info --format '{{.DefaultRuntime}}' 2>/dev/null || echo unknown)"
_flag_ok=false
grep -Eq '^[[:space:]]*accept-nvidia-visible-devices-as-volume-mounts[[:space:]]*=[[:space:]]*true' \
  "${RT_CONFIG}" 2>/dev/null && _flag_ok=true

if [[ "${_rt}" == "nvidia" && "${_flag_ok}" == "true" ]]; then
  echo ""
  echo "✅ GPU host setup complete. default-runtime=nvidia, volume-mount flag survived restart."
  echo "   Now create the cluster:  make up GPU_ENABLED=true OLLAMA_GPU=true"
else
  echo ""
  echo "⚠️  Post-restart check failed: default-runtime='${_rt}' (want nvidia)," >&2
  echo "    volume-mount flag present in ${RT_CONFIG}: ${_flag_ok} (want true)." >&2
  [[ "${FLAVOR}" == "snap" ]] && \
    echo "    If the flag didn't stick, inspect: sudo snap get docker nvidia-support" >&2
  exit 1
fi
