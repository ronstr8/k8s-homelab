.PHONY: all up down status logs fix-context clean

all: up

help:
	@echo "Homelab Kubernetes Cluster (Kind)"
	@echo "Usage:"
	@echo "  make up      - Create the local Kind cluster and Docker registry"
	@echo "  make down    - Destroy the Kind cluster and registry"

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

clean:
