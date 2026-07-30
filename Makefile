# Load local config — copy .env.example to .env and fill it in.
# Values here override the ?= defaults below; command-line args override everything.
-include .env

CLUSTER_NAME     ?= homelab
REGISTRY_NAME    ?= kind-registry
REGISTRY_PORT    ?= 5000
STORAGE_PATH     ?= $(HOME)/.local/share/k8s-volumes
ACME_EMAIL       ?=
# Space-separated public domains this cluster's ingress serves. Rewritten in
# CoreDNS to the ingress service so ACME HTTP-01 self-checks pass behind NAT.
ACME_SELFCHECK_DOMAINS ?=
MONITORING       ?= false
# Persist cert-manager TLS certs + ACME account keys across recreates (save on
# down, restore on up) so a teardown doesn't force Let's Encrypt re-issuance.
CERT_PERSIST     ?= false
GRAFANA_PASSWORD ?= homelab
TEARDOWN_GRACE   ?= 60

# ── Pause / resume — suspend the cluster for host maintenance ────────────────
# `make pause` quiesces workloads and stops the node container without deleting
# the cluster, so `make resume` brings everything back with Helm releases and
# etcd intact. Use this for hardware swaps and reboots; use `make down` only
# when you actually want the cluster gone.
PAUSE_GRACE      ?= 120
PAUSE_STATE_DIR  ?= $(STORAGE_PATH)/.pause-state
# Deployments that own a database and need an uncontended window to checkpoint.
# Drained after the rest of the app tier, before StatefulSets. "namespace/name".
PAUSE_LAST       ?=
# Namespaces left running through a pause — control plane and storage machinery.
# ingress-nginx is deliberately absent: it's the traffic gate and drains first.
PAUSE_SKIP_NAMESPACES ?= kube-system kube-public kube-node-lease local-path-storage cert-manager
RESUME_TIMEOUT   ?= 300

# ── Component versions — pin these so make recreate restores identically ─────
CERT_MANAGER_VERSION     ?= v1.14.2
INGRESS_NGINX_VERSION    ?= controller-v1.11.3
PROMETHEUS_CHART_VERSION ?=
# Leave PROMETHEUS_CHART_VERSION empty for latest, or pin after first install:
#   helm list -n monitoring -o json | jq -r '.[0].chart'

# ── GPU ──────────────────────────────────────────────────────────────────────
# GPU_ENABLED=true exposes the host GPU to the KinD node and installs the
# device plugin so pods can request nvidia.com/gpu resources.
# Requires: nvidia-container-toolkit + Docker default-runtime=nvidia.
# Changing this after cluster creation requires: make recreate GPU_ENABLED=true
GPU_ENABLED                  ?= false
GPU_VENDOR                   ?= nvidia
NVIDIA_DEVICE_PLUGIN_VERSION ?= v0.16.0

# ── Ollama (local LLM inference) ─────────────────────────────────────────────
OLLAMA             ?= false
OLLAMA_DATA_PATH   ?= $(HOME)/.ollama
OLLAMA_MODEL       ?= gemma3:12b
# 32K, not 64K: gemma3:12b weights (~8GB) + vision tower + a 64K KV cache lands
# around 14GB of a 16GB card. Halving the context buys back ~2GB of headroom.
OLLAMA_CONTEXT_LENGTH ?= 32768
OLLAMA_NAMESPACE   ?= ollama
OLLAMA_STORAGE     ?= 20Gi
OLLAMA_CPU_REQ     ?= 2
OLLAMA_CPU_LIM     ?= 4
OLLAMA_MEM_REQ     ?= 4Gi
OLLAMA_MEM_LIM     ?= 12Gi
OLLAMA_GPU         ?= false
OLLAMA_GPU_COUNT   ?= 1
OLLAMA_INGRESS_HOST ?=

# ── Host identity — PV files on the host will be owned by this UID/GID ───────
HOST_UID ?= $(shell id -u)
HOST_GID ?= $(shell id -g)

# ── Hermes Agent ─────────────────────────────────────────────────────────────
# HERMES_DATA_PATH is bind-mounted into the kind node at cluster creation time
# (make up HERMES=true / make recreate HERMES=true). Changing it retroactively
# requires a recreate, or: ln -s <old-path> <STORAGE_PATH>/hermes and set
# HERMES_DATA_PATH=$(STORAGE_PATH)/hermes.
HERMES                        ?= false
# Pinned to a tested digest for reproducibility; bump to update (or override in .env).
HERMES_IMAGE                  ?= nousresearch/hermes-agent@sha256:dd3d1ecaf75d8820ed74775dbb77177cff8e1bab2946c42a5d91d30ae427dac4
HERMES_NAMESPACE              ?= hermes
HERMES_DATA_PATH              ?= $(HOME)/.hermes
HERMES_UID                    ?= $(shell id -u)
HERMES_GID                    ?= $(shell id -g)
HERMES_DASHBOARD              ?= true
HERMES_DASHBOARD_PORT         ?= 9119
HERMES_DASHBOARD_INGRESS_HOST ?=
HERMES_DASHBOARD_CLUSTER_ISSUER ?=
HERMES_DASHBOARD_OAUTH_CLIENT_ID ?=
HERMES_CPU_REQ                ?= 500m
HERMES_CPU_LIM                ?= 2
HERMES_MEM_REQ                ?= 512Mi
HERMES_MEM_LIM                ?= 2Gi

export CLUSTER_NAME REGISTRY_NAME REGISTRY_PORT STORAGE_PATH ACME_EMAIL ACME_SELFCHECK_DOMAINS MONITORING GRAFANA_PASSWORD TEARDOWN_GRACE HOSTS CERT_PERSIST CERT_BACKUP_DIR
export PAUSE_GRACE PAUSE_STATE_DIR PAUSE_LAST PAUSE_SKIP_NAMESPACES RESUME_TIMEOUT
export CERT_MANAGER_VERSION INGRESS_NGINX_VERSION PROMETHEUS_CHART_VERSION
export GPU_ENABLED GPU_VENDOR NVIDIA_DEVICE_PLUGIN_VERSION
export OLLAMA OLLAMA_DATA_PATH OLLAMA_MODEL OLLAMA_CONTEXT_LENGTH OLLAMA_NAMESPACE OLLAMA_STORAGE
export OLLAMA_CPU_REQ OLLAMA_CPU_LIM OLLAMA_MEM_REQ OLLAMA_MEM_LIM
export OLLAMA_GPU OLLAMA_GPU_COUNT OLLAMA_INGRESS_HOST
export HERMES HERMES_IMAGE HERMES_NAMESPACE HERMES_DATA_PATH HERMES_UID HERMES_GID
export HERMES_DASHBOARD HERMES_DASHBOARD_PORT HERMES_DASHBOARD_INGRESS_HOST HERMES_DASHBOARD_OAUTH_CLIENT_ID
export HERMES_DASHBOARD_HOST HERMES_API_SERVER_KEY
export HERMES_DASHBOARD_CLUSTER_ISSUER
export HERMES_CPU_REQ HERMES_CPU_LIM HERMES_MEM_REQ HERMES_MEM_LIM
export HOST_UID HOST_GID

.PHONY: all up down pause resume status logs fix-context clean env hosts setup-gpu certs-save certs-restore monitoring monitoring-down ollama ollama-down hermes hermes-down

all: up

help:
	@echo "Homelab Kubernetes Cluster (Kind)"
	@echo "Usage:"
	@echo "  make env                            - Copy .env.example → .env (first-time setup)"
	@echo "  make up                             - Create the local Kind cluster and Docker registry"
	@echo "  make up MONITORING=true             - Also install monitoring (Prometheus + Grafana)"
	@echo "  make setup-gpu                      - One-time NVIDIA host config for GPU passthrough (needs sudo)"
	@echo "  make certs-save / certs-restore     - Back up/restore TLS certs across recreates (auto via CERT_PERSIST)"
	@echo "  make up GPU_ENABLED=true            - Expose host GPU to cluster + install device plugin"
	@echo "  make up OLLAMA=true                 - Also deploy Ollama (pulls OLLAMA_MODEL at runtime)"
	@echo "  make pause                          - Quiesce workloads + stop the node (host maintenance)"
	@echo "  make resume                         - Restart the node and restore workloads after a pause"
	@echo "  make down                           - Destroy the Kind cluster and registry"
	@echo "  make recreate                       - down + up (required when changing GPU_ENABLED)"
	@echo "  make hosts                          - Sync /etc/hosts to the current node IP (needs sudo)"
	@echo "  make monitoring                     - Install/upgrade monitoring on existing cluster"
	@echo "  make monitoring-down                - Remove monitoring stack"
	@echo "  make ollama                         - Deploy/upgrade Ollama on existing cluster"
	@echo "  make ollama-down                    - Remove Ollama (preserves model data on host)"
	@echo ""
	@echo "Key variables (export or pass on command line):"
	@echo "  GPU_ENABLED=true                    - Enable GPU passthrough to KinD"
	@echo "  GPU_VENDOR=nvidia                   - GPU vendor (only 'nvidia' supported)"
	@echo "  NVIDIA_DEVICE_PLUGIN_VERSION=v0.16.0"
	@echo "  OLLAMA_MODEL=gemma3:12b             - Model pulled at pod startup"
	@echo "  OLLAMA_CONTEXT_LENGTH=32768         - Serving context window (server-wide ceiling)"
	@echo "  OLLAMA_NAMESPACE=ollama"
	@echo "  OLLAMA_STORAGE=20Gi                 - PV size for model cache"
	@echo "  OLLAMA_CPU_REQ=2  OLLAMA_CPU_LIM=4"
	@echo "  OLLAMA_MEM_REQ=4Gi  OLLAMA_MEM_LIM=12Gi"
	@echo "  OLLAMA_GPU=false                    - Request nvidia.com/gpu in the Ollama pod"
	@echo "  OLLAMA_GPU_COUNT=1"
	@echo "  OLLAMA_INGRESS_HOST=                - Hostname for Ingress (empty = ClusterIP only)"
	@echo "  HERMES_IMAGE=nousresearch/hermes-agent@sha256:... (pinned; override to change)"
	@echo "  HERMES_DATA_PATH=~/.hermes          - Host path bind-mounted into the kind node"
	@echo "  HERMES_UID / HERMES_GID             - UID/GID for s6-overlay volume chown (default: current user)"
	@echo "  HERMES_DASHBOARD=true               - Enable dashboard service on HERMES_DASHBOARD_PORT"
	@echo "  HERMES_DASHBOARD_PORT=9119"
	@echo "  HERMES_DASHBOARD_INGRESS_HOST=      - Hostname for dashboard Ingress"
	@echo "  HERMES_CPU_REQ=500m  HERMES_CPU_LIM=2"
	@echo "  HERMES_MEM_REQ=512Mi  HERMES_MEM_LIM=2Gi"
	@echo "  PAUSE_LAST=ns/deploy                - Deployments drained last, before StatefulSets"
	@echo "  PAUSE_GRACE=120                     - Per-workload drain + docker stop timeout"

env:
	@if [ -f .env ]; then echo ".env already exists — edit it directly."; \
	else cp .env.example .env && echo "Created .env — open it and set ACME_EMAIL at minimum."; fi

up:
	@bash scripts/kind-setup.sh

setup-gpu:
	@bash scripts/gpu-host-setup.sh

certs-save:
	@bash scripts/cert-persist.sh save

certs-restore:
	@bash scripts/cert-persist.sh restore

down:
	@bash scripts/kind-teardown.sh

pause:
	@bash scripts/cluster-pause.sh

resume:
	@bash scripts/cluster-resume.sh

recreate: down up

status:
	@echo "☸️  Kind Clusters:"
	@kind get clusters
	@echo "\n🐳 Docker Containers (Kind):"
	@docker ps --filter "label=io.x-k8s.kind.cluster"
	@echo "\n☸️  Kubernetes Nodes:"
	@kubectl get nodes 2>/dev/null || echo "❌ Could not connect to cluster API (localhost:8080?)"
	@echo "\n☸️  Current Context:"
	@kubectl config current-context 2>/dev/null || echo "❌ No context set"

fix-context:
	@echo "🔧 Repairing kubectl context for '$(CLUSTER_NAME)'..."
	@kind export kubeconfig --name $(CLUSTER_NAME)

logs:
	@echo "📋 Dumping Kind control-plane logs..."
	@docker logs $(CLUSTER_NAME)-control-plane

hosts:
	@bash scripts/update-hosts.sh

monitoring:
	@bash scripts/monitoring-setup.sh

monitoring-down:
	@bash scripts/monitoring-teardown.sh

ollama:
	@bash scripts/ollama-setup.sh

ollama-down:
	@bash scripts/ollama-teardown.sh

hermes:
	@bash scripts/hermes-setup.sh

hermes-down:
	@bash scripts/hermes-teardown.sh

clean:
	@echo "🧹 Removing generated data under STORAGE_PATH (models, metrics, dashboards)..."
	@echo "   STORAGE_PATH = $(STORAGE_PATH)"
	@read -p "   This deletes all PV data on the host. Continue? [y/N] " ans && [ "$$ans" = "y" ] || exit 0
	@rm -rf "$(STORAGE_PATH)"
	@echo "✅ Done."
