CLUSTER_NAME     ?= homelab
REGISTRY_NAME    ?= kind-registry
REGISTRY_PORT    ?= 5000
STORAGE_PATH     ?= $(HOME)/.local/share/k8s-volumes
ACME_EMAIL       ?=
MONITORING       ?= false
GRAFANA_PASSWORD ?= homelab

# ── GPU ──────────────────────────────────────────────────────────────────────
# GPU_ENABLED=true exposes the host GPU to the KinD node and installs the
# device plugin so pods can request nvidia.com/gpu resources.
# Requires: nvidia-container-toolkit + Docker default-runtime=nvidia.
# Changing this after cluster creation requires: make recreate GPU_ENABLED=true
GPU_ENABLED                  ?= true
GPU_VENDOR                   ?= nvidia
NVIDIA_DEVICE_PLUGIN_VERSION ?= v0.16.0

# ── Ollama (local LLM inference) ─────────────────────────────────────────────
OLLAMA             ?= true
OLLAMA_MODEL       ?= llama3.2:3b
OLLAMA_NAMESPACE   ?= ollama
OLLAMA_STORAGE     ?= 20Gi
OLLAMA_CPU_REQ     ?= 2
OLLAMA_CPU_LIM     ?= 4
OLLAMA_MEM_REQ     ?= 4Gi
OLLAMA_MEM_LIM     ?= 8Gi
OLLAMA_GPU         ?= false
OLLAMA_GPU_COUNT   ?= 1
OLLAMA_INGRESS_HOST ?=

export CLUSTER_NAME REGISTRY_NAME REGISTRY_PORT STORAGE_PATH ACME_EMAIL MONITORING GRAFANA_PASSWORD
export GPU_ENABLED GPU_VENDOR NVIDIA_DEVICE_PLUGIN_VERSION
export OLLAMA OLLAMA_MODEL OLLAMA_NAMESPACE OLLAMA_STORAGE
export OLLAMA_CPU_REQ OLLAMA_CPU_LIM OLLAMA_MEM_REQ OLLAMA_MEM_LIM
export OLLAMA_GPU OLLAMA_GPU_COUNT OLLAMA_INGRESS_HOST

.PHONY: all up down status logs fix-context clean monitoring monitoring-down ollama ollama-down

all: up

help:
	@echo "Homelab Kubernetes Cluster (Kind)"
	@echo "Usage:"
	@echo "  make up                             - Create the local Kind cluster and Docker registry"
	@echo "  make up MONITORING=true             - Also install monitoring (Prometheus + Grafana)"
	@echo "  make up GPU_ENABLED=true            - Expose host GPU to cluster + install device plugin"
	@echo "  make up OLLAMA=true                 - Also deploy Ollama (pulls OLLAMA_MODEL at runtime)"
	@echo "  make down                           - Destroy the Kind cluster and registry"
	@echo "  make recreate                       - down + up (required when changing GPU_ENABLED)"
	@echo "  make monitoring                     - Install/upgrade monitoring on existing cluster"
	@echo "  make monitoring-down                - Remove monitoring stack"
	@echo "  make ollama                         - Deploy/upgrade Ollama on existing cluster"
	@echo "  make ollama-down                    - Remove Ollama (preserves model data on host)"
	@echo ""
	@echo "Key variables (export or pass on command line):"
	@echo "  GPU_ENABLED=true                    - Enable GPU passthrough to KinD"
	@echo "  GPU_VENDOR=nvidia                   - GPU vendor (only 'nvidia' supported)"
	@echo "  NVIDIA_DEVICE_PLUGIN_VERSION=v0.16.0"
	@echo "  OLLAMA_MODEL=llama3.2:3b            - Model pulled at pod startup"
	@echo "  OLLAMA_NAMESPACE=ollama"
	@echo "  OLLAMA_STORAGE=20Gi                 - PV size for model cache"
	@echo "  OLLAMA_CPU_REQ=2  OLLAMA_CPU_LIM=4"
	@echo "  OLLAMA_MEM_REQ=4Gi  OLLAMA_MEM_LIM=8Gi"
	@echo "  OLLAMA_GPU=false                    - Request nvidia.com/gpu in the Ollama pod"
	@echo "  OLLAMA_GPU_COUNT=1"
	@echo "  OLLAMA_INGRESS_HOST=                - Hostname for Ingress (empty = ClusterIP only)"

up:
	@bash scripts/kind-setup.sh

down:
	@bash scripts/kind-teardown.sh

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
	@echo "🔧 Repairing kubectl context for '${CLUSTER_NAME}'..."
	@kind export kubeconfig --name $$(CLUSTER_NAME:-homelab)

logs:
	@echo "📋 Dumping Kind control-plane logs..."
	@docker logs $$(CLUSTER_NAME:-homelab)-control-plane

monitoring:
	@bash scripts/monitoring-setup.sh

monitoring-down:
	@bash scripts/monitoring-teardown.sh

ollama:
	@bash scripts/ollama-setup.sh

ollama-down:
	@bash scripts/ollama-teardown.sh

clean:
