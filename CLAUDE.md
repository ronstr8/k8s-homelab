# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for a local Kubernetes homelab using [Kind](https://kind.sigs.k8s.io/). It provisions a single-node cluster with a local Docker registry, Nginx Ingress, cert-manager, and shared ClusterIssuers for three projects: **wordwonk**, **poker**, and **moor** (fazigu.org subdomains).

## Commands

```bash
make up         # Create cluster + all services (idempotent — safe to re-run)
make down       # Destroy cluster and registry
make recreate   # down then up
make status     # Show cluster/node/context state
make fix-context # Repair kubectl context if it breaks
make logs       # Dump control-plane container logs
```

Environment variable overrides (export before `make`):

```bash
CLUSTER_NAME=homelab       # default
REGISTRY_PORT=5000         # default, registry at localhost:5000
ACME_EMAIL=you@example.com # required — used in ClusterIssuer for Let's Encrypt
STORAGE_PATH=~/.local/share/k8s-volumes  # host path for PV data
```

## Architecture

`scripts/kind-setup.sh` is the core script, run by `make up`. It:

1. Creates a local Docker registry container (`kind-registry`) on `localhost:5000`
2. Creates the Kind cluster (`homelab`) with node image `kindest/node:v1.31.0`
   - Mounts `STORAGE_PATH` → `/mnt/k8s-volumes` inside the node
   - Maps host ports 80, 443, and 8888 to the control-plane container
3. Connects the registry to the Kind Docker network and configures containerd on each node to resolve `localhost:5000` → `kind-registry:5000`
4. Deploys Nginx Ingress Controller from upstream Kind manifests
5. Installs cert-manager v1.14.2 and applies `resources/cluster-issuers.yaml`
6. Patches Nginx Ingress to expose port 8888 as a raw TCP passthrough to `moor/moor-telnet-host:8888`

## Shared resources available to all projects

- **Registry**: Push images to `localhost:5000/<image>`, pull inside the cluster as `localhost:5000/<image>`
- **Storage**: Host path at `STORAGE_PATH`; projects must create their own subdirectory (e.g., `mkdir -p $STORAGE_PATH/project-name`) before deploying to avoid collisions
- **ClusterIssuers**:
  - `selfsigned-issuer` — local/dev TLS
  - `letsencrypt-prod` — public ACME (requires DNS resolution to the host)

## /etc/hosts

After `make up`, the script prints the Kind control-plane IP. Add it to `/etc/hosts`:

```
<node-ip>  wordwonk.fazigu.org poker.fazigu.org moor.fazigu.org
```
