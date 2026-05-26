CLUSTER_NAME     ?= homelab
REGISTRY_NAME    ?= kind-registry
REGISTRY_PORT    ?= 5000
STORAGE_PATH     ?= $(HOME)/.local/share/k8s-volumes
ACME_EMAIL       ?=
MONITORING       ?= false
GRAFANA_PASSWORD ?= homelab

export CLUSTER_NAME REGISTRY_NAME REGISTRY_PORT STORAGE_PATH ACME_EMAIL MONITORING GRAFANA_PASSWORD

.PHONY: all up down status logs fix-context clean monitoring monitoring-down

all: up

help:
	@echo "Homelab Kubernetes Cluster (Kind)"
	@echo "Usage:"
	@echo "  make up                    - Create the local Kind cluster and Docker registry"
	@echo "  make up MONITORING=true    - Also install the monitoring stack (Prometheus + Grafana)"
	@echo "  make down                  - Destroy the Kind cluster and registry"
	@echo "  make monitoring            - Install/upgrade monitoring stack on existing cluster"
	@echo "  make monitoring-down       - Remove monitoring stack"

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

clean:
