# k8s-homelab

Your centralized repository for managing local Kubernetes clusters using [Kind](https://kind.sigs.k8s.io/).

## Prerequisites

- **Docker**
- **Kind**
- **kubectl**

## Cluster Management

By default, the cluster is named `homelab`.

### Included Services

- **Registry**: Local Docker registry on `localhost:5000`.
- **Ingress**: Nginx Ingress Controller on 80/443 (with 8888 for telnet support).
- **cert-manager**: Installed and configured with shared `ClusterIssuers`.

## Cluster Management

To spin up the cluster and all services:

```bash
make up
```

To tear everything down:

```bash
make down
```

## Shared Resources

### Certificate Management (cert-manager)

The following `ClusterIssuers` are available globally:

- `selfsigned-issuer`: For local development certificates.
- `letsencrypt-prod`: For production ACME certificates (requires public DNS).

Namespaces can request certificates by referencing these issuers in their `Certificate` or `Ingress` resources.

### Storage Management

The cluster provides a generic host-path mount at `/mnt/moor-storage` inside the nodes, which maps to `${STORAGE_PATH}` on your host (default: `~/.local/share/k8s-volumes`).

**Important**: Projects are responsible for creating their own subdirectories within this path to avoid namespace collisions and ensure clean separation of data. For example, a project's Makefile should run `mkdir -p $(STORAGE_PATH)/project-name` before deploying.

### Advanced Usage

You can override the default cluster name or registry configuration by exporting environment variables before running `make`:

```bash
export ACME_EMAIL="your-email@example.com"
export CLUSTER_NAME="custom-cluster"
export REGISTRY_PORT="5001"
make up
```
