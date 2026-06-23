# k8s-homelab

A single-node Kubernetes cluster on your home machine using [Kind](https://kind.sigs.k8s.io/). Designed for running real workloads behind a cable modem — not a toy demo cluster.

What you get out of the box:
- Local Docker registry on `localhost:5000`
- Nginx Ingress on ports 80, 443, and 8888
- cert-manager with `selfsigned-issuer`, `letsencrypt-staging`, and `letsencrypt-prod` ClusterIssuers
- `local-path-provisioner` as the default `standard` StorageClass, redirected to `STORAGE_PATH`
- Host-path storage at `~/.local/share/k8s-volumes` owned by your user

Optional add-ons: monitoring (Prometheus + Grafana + Alertmanager), Ollama (local LLM inference), Hermes Agent.

---

## Prerequisites

- **Docker** — running and accessible without sudo
- **Kind** — `brew install kind` or https://kind.sigs.k8s.io/docs/user/quick-start/#installation
- **kubectl** — https://kubernetes.io/docs/tasks/tools/
- **Helm** — required for monitoring; optional otherwise
- **inotify limits raised** — Kind + Docker chew through the default quickly; do this once:
  ```bash
  echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
  echo fs.inotify.max_user_instances=512  | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  ```

**If you have an NVIDIA GPU** — you need `nvidia-container-toolkit`, Docker's default runtime set to `nvidia`, **and** the toolkit configured to honor the kind node's GPU volume-mount request. One-time setup:

```bash
# Install nvidia-container-toolkit:
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html

# 1. Set Docker's default runtime to nvidia
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "/usr/bin/nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF

# 2. Let the kind node claim all GPUs via its volume-mount sentinel. Without this
#    the node gets bare /dev/nvidia* devices but no driver/NVML, the in-cluster
#    device plugin finds no GPUs, and GPU pods sit Pending forever.
sudo nvidia-ctk config --in-place --set accept-nvidia-visible-devices-as-volume-mounts=true

sudo systemctl restart docker
```

> **Snap Docker** (Ubuntu Core / `snap install docker`): the daemon config in step 1 lives at `/var/snap/docker/current/config/daemon.json`, **not** `/etc/docker/daemon.json` (snap ignores the latter), and you restart with `sudo snap restart docker`. Step 2 is host-level and unchanged. Confirm both took effect with `docker info | grep "Default Runtime"` (should print `nvidia`).

---

## Quick Start

First time setup:

```bash
make env          # copies .env.example → .env
```

Open `.env` and set `ACME_EMAIL` at minimum. Then:

```bash
make up
```

The script is idempotent — re-running `make up` won't blow anything away.

After it finishes it prints the cluster IP. Add it to `/etc/hosts` for local name resolution:

```
<node-ip>  logodal.com poker.fazigu.org moor.fazigu.org
```

---

## GOTCHA: GPU and Ollama default to off

`.env.example` defaults `GPU_ENABLED=false` and `OLLAMA=false`. If you want GPU passthrough, see the GPU prerequisite section above, then set `GPU_ENABLED=true` in `.env`.

If you previously exported `GPU_ENABLED=true` in your shell without the NVIDIA toolkit configured, the setup will fail at the GPU preflight check. Fix it with:

```bash
make up GPU_ENABLED=false OLLAMA=false
```

---

## Let's Encrypt on a Home Cable Modem

Three ClusterIssuers are available:

| Issuer | Use case |
|---|---|
| `selfsigned-issuer` | Local dev, no internet required |
| `letsencrypt-staging` | Test ACME flow without hitting rate limits |
| `letsencrypt-prod` | Public domains with real certs |

`letsencrypt-prod` only works if you have a domain pointed at your public IP, ports 80/443 forwarded from your router, and your ISP doesn't block inbound port 80. Start with `letsencrypt-staging` to verify the ACME pipeline works before switching to prod.

Reference an issuer in your manifests:

```yaml
cert-manager.io/cluster-issuer: letsencrypt-staging
```

---

## Make Targets

```bash
make env             # Copy .env.example → .env (first-time only)
make up              # Create cluster + all services
make down            # Gracefully drain optional namespaces, destroy cluster and registry
make recreate        # down then up (required when changing GPU_ENABLED, HERMES, or OLLAMA)
make clean           # Prompts for confirmation, then deletes STORAGE_PATH on the host
make status          # Show cluster/node/context state
make fix-context     # Repair kubectl context if it breaks
make logs            # Dump control-plane container logs
make help            # Full variable reference
```

---

## Configuration

Copy `.env.example` to `.env` with `make env`. All variables can also be exported or passed on the `make` command line — command-line args override `.env`.

| Variable | Default | Notes |
|---|---|---|
| `ACME_EMAIL` | (required) | Used in Let's Encrypt ClusterIssuers |
| `CLUSTER_NAME` | `homelab` | |
| `REGISTRY_PORT` | `5000` | Registry at `localhost:5000` |
| `STORAGE_PATH` | `~/.local/share/k8s-volumes` | Host path for PV data, owned by `HOST_UID:HOST_GID` |
| `HOST_UID` / `HOST_GID` | current user | PV directories are chowned to this on creation |
| `GPU_ENABLED` | `false` | Requires NVIDIA toolkit + Docker `default-runtime=nvidia` |
| `TEARDOWN_GRACE` | `60` | Seconds to wait when draining namespaces on `make down` |
| `MONITORING` | `false` | Prometheus + Grafana + Alertmanager |
| `OLLAMA` | `false` | Local LLM inference — must be set at cluster creation time |
| `HERMES` | `false` | Hermes Agent — must be set at cluster creation time |

### Component version pinning

These Makefile vars control what gets installed. Set them in `.env` to make `make recreate` deterministic:

| Variable | Default |
|---|---|
| `CERT_MANAGER_VERSION` | `v1.14.2` |
| `INGRESS_NGINX_VERSION` | `controller-v1.11.3` |
| `PROMETHEUS_CHART_VERSION` | (latest) |

After first install, pin the Prometheus chart version so recreates restore the exact same stack:

```bash
helm list -A -o json | jq -r '.[] | .name + " " + .chart'
```

Copy the `kube-prometheus-stack-XX.X.X` value into `.env` as `PROMETHEUS_CHART_VERSION`.

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

`local-path-provisioner` is redirected from its default path to `STORAGE_PATH` on the host. PVCs using the `standard` StorageClass provision automatically there, owned by `HOST_UID:HOST_GID`.

For explicit host-path volumes, the cluster mounts `STORAGE_PATH` → `/mnt/k8s-volumes` inside the node. Create a subdirectory before deploying:

```bash
mkdir -p ~/.local/share/k8s-volumes/my-project
```

### ClusterIssuers

| Issuer | Use case |
|---|---|
| `selfsigned-issuer` | Local dev |
| `letsencrypt-staging` | ACME testing |
| `letsencrypt-prod` | Public domains |

---

## Optional Components

### Monitoring (Prometheus + Grafana + Alertmanager)

```bash
# Enable at cluster creation:
make up MONITORING=true

# Add to an existing cluster:
make monitoring

# Remove:
make monitoring-down
```

Default Grafana password: `homelab` (override with `GRAFANA_PASSWORD`).

Alertmanager is enabled with a null receiver by default. To add email alerts, edit `resources/monitoring-values.yaml` — there's a commented-out email config block.

After install, pin `PROMETHEUS_CHART_VERSION` in `.env` so recreates land on the same chart version (see Configuration above).

### Ollama (Local LLM Inference)

Ollama shares model storage with a host Ollama install. `OLLAMA_DATA_PATH` defaults to `~/.ollama` — the same directory a native `ollama` binary uses. No duplicate downloads.

`OLLAMA_DATA_PATH` must be set **at cluster creation time** — the path is bind-mounted into the Kind node during `make up`. If you need to change it, run `make recreate`.

```bash
# CPU-only, using default ~/.ollama for model storage:
make up OLLAMA=true GPU_ENABLED=false OLLAMA_GPU=false

# With GPU passthrough:
make up GPU_ENABLED=true OLLAMA=true OLLAMA_GPU=true

# Add to an existing cluster:
make ollama OLLAMA_GPU=false

# Remove (model data on host is untouched):
make ollama-down
```

Key variables:

| Variable | Default | Notes |
|---|---|---|
| `OLLAMA_DATA_PATH` | `~/.ollama` | Shared with host Ollama; bind-mounted at cluster creation |
| `OLLAMA_MODEL` | `qwen2.5:7b-instruct-q6_K` | Pulled at pod startup; cached on subsequent restarts |
| `OLLAMA_CONTEXT_LENGTH` | `65536` | Serving context window; Ollama defaults to 2048 otherwise (Hermes needs ≥64K) |
| `OLLAMA_STORAGE` | `20Gi` | PV size declared for the mount |
| `OLLAMA_GPU` | `false` | Request `nvidia.com/gpu` in the pod |
| `OLLAMA_INGRESS_HOST` | (empty) | Set a hostname to expose via Ingress; empty = ClusterIP only |

The Ollama pod runs as `HOST_UID` so model files stay user-owned on the host.

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
| `HERMES_DATA_PATH` | `~/.hermes` | Bind-mounted into the Kind node at cluster creation |
| `HERMES_DASHBOARD` | `true` | Enables dashboard on `HERMES_DASHBOARD_PORT` |
| `HERMES_DASHBOARD_PORT` | `9119` | Dashboard is ClusterIP only — use port-forward |

Port-forward to the dashboard:

```bash
kubectl port-forward -n hermes svc/hermes-dashboard 9119:9119
```

To run Hermes against the in-cluster Ollama, point the `model` block in
`~/.hermes/config.yaml` at Ollama's OpenAI-compatible endpoint (this file is the
same one the pod reads — it's bind-mounted into the node, not baked into the image):

```yaml
model:
  default: qwen2.5:7b-instruct-q6_K
  provider: openai
  base_url: http://ollama.ollama.svc.cluster.local:11434/v1
  api_key: ollama        # Ollama ignores the value; any non-empty string works
  context_length: 65536  # must match OLLAMA_CONTEXT_LENGTH; Hermes Agent needs >=64K
```

Restart the running gateway to reload it: `kubectl rollout restart deploy/hermes -n hermes`.

---

## Troubleshooting

**kubectl context is broken after a Docker restart:**

```bash
make fix-context
```

**GPU preflight fails:**

The preflight checks `nvidia-smi`, `nvidia-container-toolkit`, Docker's default runtime, and `accept-nvidia-visible-devices-as-volume-mounts`. If it stops on the last one, enable it (then recreate so the node is rebuilt under the nvidia runtime):

```bash
sudo nvidia-ctk config --in-place --set accept-nvidia-visible-devices-as-volume-mounts=true
sudo systemctl restart docker   # snap Docker: sudo snap restart docker
make recreate
```

Or skip the GPU entirely:

```bash
make up GPU_ENABLED=false OLLAMA=false
```

**Cluster already exists but API server is unresponsive:**

`make up` detects this and deletes/recreates the cluster automatically.

**Hermes or Ollama data not visible in pod:**

The Kind node needs the bind mount from cluster creation. If you skipped the flag at `make up` time:

```bash
# Option A: recreate the cluster
make recreate HERMES=true

# Option B: symlink into the existing storage mount
ln -s ~/.hermes ~/.local/share/k8s-volumes/hermes
make hermes HERMES_DATA_PATH=~/.local/share/k8s-volumes/hermes
```

**Delete all PV data on the host:**

```bash
make clean   # prompts for confirmation before deleting STORAGE_PATH
```
