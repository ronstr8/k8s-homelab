# k8s-homelab

A single-node Kubernetes cluster on your home machine using [Kind](https://kind.sigs.k8s.io/). Designed for running real workloads behind a cable modem — not a toy demo cluster.

What you get out of the box:
- Local Docker registry on `localhost:5000`
- Nginx Ingress on ports 80, 443, and 8888
- cert-manager with `selfsigned-issuer` and `letsencrypt-prod` ClusterIssuers
- `local-path-provisioner` as the default `standard` StorageClass (Kind ships this)
- Host-path storage mounted at `~/.local/share/k8s-volumes`

Optional add-ons: monitoring (Prometheus + Grafana), Ollama (local LLM inference), Hermes Agent.

---

## Prerequisites

- **Docker** — running and accessible without sudo
- **Kind** — `brew install kind` or https://kind.sigs.k8s.io/docs/user/quick-start/#installation
- **kubectl** — https://kubernetes.io/docs/tasks/tools/
- **Helm** — required for monitoring; optional otherwise
- **An email address** — used in the Let's Encrypt ClusterIssuer

---

## Quick Start

```bash
export ACME_EMAIL=you@example.com
make up
```

That's it. The script is idempotent — re-running `make up` won't blow anything away.

After it finishes, it prints a cluster IP. Add it to `/etc/hosts` for local name resolution:

```
<node-ip>  logodal.com poker.fazigu.org moor.fazigu.org
```

(There's no `make hosts` target yet — manual step for now.)

---

## GOTCHA: GPU and Ollama are on by default

The Makefile defaults `GPU_ENABLED=true` and `OLLAMA=true`. If you don't have an NVIDIA GPU set up with `nvidia-container-toolkit` and Docker's default runtime set to `nvidia`, **`make up` will fail** at the GPU preflight check.

**If you don't have a GPU:**

```bash
make up GPU_ENABLED=false OLLAMA=false
```

Or just export them:

```bash
export GPU_ENABLED=false
export OLLAMA=false
export ACME_EMAIL=you@example.com
make up
```

---

## Let's Encrypt on a Home Cable Modem

The `letsencrypt-prod` ClusterIssuer is configured and ready, but it only works if:

1. You have a domain name pointed at your public IP
2. Your router forwards ports 80 and 443 to your machine
3. Your ISP doesn't block inbound port 80 (many residential ISPs do)

If any of that isn't true, **use `selfsigned-issuer` instead.** It works fine for local dev and avoids Let's Encrypt rate limits. Just reference it in your `Certificate` or `Ingress` annotations:

```yaml
cert-manager.io/cluster-issuer: selfsigned-issuer
```

The `letsencrypt-prod` issuer is there when you're ready — it just needs real public DNS resolution to do the ACME HTTP-01 challenge.

---

## Make Targets

```bash
make up              # Create cluster + all services
make down            # Destroy cluster and registry
make recreate        # down then up (required when changing GPU_ENABLED or HERMES)
make status          # Show cluster/node/context state
make fix-context     # Repair kubectl context if it breaks
make logs            # Dump control-plane container logs
make help            # Full variable reference
```

---

## Configuration

All variables can be exported or passed on the `make` command line.

| Variable | Default | Notes |
|---|---|---|
| `ACME_EMAIL` | (required) | Used in Let's Encrypt ClusterIssuer |
| `CLUSTER_NAME` | `homelab` | |
| `REGISTRY_PORT` | `5000` | Registry at `localhost:5000` |
| `STORAGE_PATH` | `~/.local/share/k8s-volumes` | Host path for PV data |
| `GPU_ENABLED` | `true` | See GOTCHA above — set `false` if no NVIDIA GPU |
| `OLLAMA` | `true` | See GOTCHA above — set `false` if skipping Ollama |
| `MONITORING` | `false` | Prometheus + Grafana |
| `HERMES` | `false` | Hermes Agent (must be set at cluster creation time) |

---

## Shared Resources

### Registry

Push images from your host:

```bash
docker push localhost:5000/my-image:tag
```

Pull from inside the cluster:

```yaml
image: localhost:5000/my-image:tag
```

### Storage

Kind ships with `local-path-provisioner` as the `standard` StorageClass. PVCs using that class provision automatically from the host.

For explicit host-path volumes, the cluster mounts `STORAGE_PATH` → `/mnt/k8s-volumes` inside the node. Create your own subdirectory before deploying:

```bash
mkdir -p ~/.local/share/k8s-volumes/my-project
```

### ClusterIssuers

| Issuer | Use case |
|---|---|
| `selfsigned-issuer` | Local dev, no internet required |
| `letsencrypt-prod` | Public domains with DNS + port forwarding |

---

## Optional Components

### Monitoring (Prometheus + Grafana)

```bash
# Enable at cluster creation:
make up MONITORING=true

# Or add to an existing cluster:
make monitoring

# Remove:
make monitoring-down
```

Default Grafana password: `homelab` (override with `GRAFANA_PASSWORD=...`).

### Ollama (Local LLM Inference)

Runs Ollama in the cluster and pulls a model at pod startup. Subsequent restarts reuse the cached model data from the PVC.

```bash
# Enable at cluster creation (CPU-only):
make up OLLAMA=true GPU_ENABLED=false OLLAMA_GPU=false

# With GPU passthrough (requires NVIDIA setup):
make up GPU_ENABLED=true OLLAMA=true OLLAMA_GPU=true

# Add to an existing cluster:
make ollama OLLAMA_GPU=false

# Remove (preserves model data on host):
make ollama-down
```

Key variables:

| Variable | Default | Notes |
|---|---|---|
| `OLLAMA_MODEL` | `llama3.2:3b` | Pulled at pod startup |
| `OLLAMA_STORAGE` | `20Gi` | PVC size for model cache |
| `OLLAMA_GPU` | `false` | Request `nvidia.com/gpu` in the pod |
| `OLLAMA_INGRESS_HOST` | (empty) | Set a hostname to expose via Ingress; empty = ClusterIP only |

In-cluster endpoint: `http://ollama.ollama.svc.cluster.local:11434`

Port-forward if no Ingress:

```bash
kubectl port-forward -n ollama svc/ollama 11434:11434
```

### Hermes Agent

Hermes requires its data directory to be bind-mounted into the Kind node **at cluster creation time**. You can't add it retroactively without a recreate.

```bash
# Create cluster with Hermes mount:
make up HERMES=true GPU_ENABLED=false OLLAMA=false

# Or recreate an existing cluster:
make recreate HERMES=true GPU_ENABLED=false OLLAMA=false

# Deploy Hermes onto the cluster:
make hermes

# Remove:
make hermes-down
```

Key variables:

| Variable | Default | Notes |
|---|---|---|
| `HERMES_DATA_PATH` | `~/.hermes` | Host path bind-mounted into the node |
| `HERMES_DASHBOARD` | `true` | Enables dashboard on `HERMES_DASHBOARD_PORT` |
| `HERMES_DASHBOARD_PORT` | `9119` | |
| `HERMES_DASHBOARD_INGRESS_HOST` | (empty) | Exposes dashboard via Ingress — only set for trusted networks, dashboard exposes API keys |

Port-forward to the dashboard:

```bash
kubectl port-forward -n hermes svc/hermes-dashboard 9119:9119
```

If you want Hermes to talk to Ollama in-cluster, set in `~/.hermes/.env`:

```bash
OLLAMA_URL=http://ollama.ollama.svc.cluster.local:11434
```

---

## Troubleshooting

**kubectl context is broken after a Docker restart:**

```bash
make fix-context
```

**GPU preflight fails:**

```bash
make up GPU_ENABLED=false OLLAMA=false
```

**Cluster already exists but API server is unresponsive:**

`make up` will detect this and delete/recreate the cluster automatically.

**Hermes data not visible in pod:**

The Kind node needs the bind mount from cluster creation. If you skipped `HERMES=true` at `make up` time:

```bash
# Option A: recreate the cluster
make recreate HERMES=true

# Option B: symlink into the existing storage mount
ln -s ~/.hermes ~/.local/share/k8s-volumes/hermes
make hermes HERMES_DATA_PATH=~/.local/share/k8s-volumes/hermes
```
