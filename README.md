# k8s-homelab

A single-node Kubernetes cluster on your home machine using [Kind](https://kind.sigs.k8s.io/). Designed for running **real workloads behind a residential cable modem / NAT** — not a toy demo cluster. It bakes in fixes for the gotchas that eat hours when you self-host on a home connection: GPU passthrough, Let's Encrypt behind NAT, and surviving cluster recreates without re-issuing certs.

What you get out of the box:
- Local Docker registry on `localhost:5000`
- Nginx Ingress on ports 80, 443, and 8888
- cert-manager with `selfsigned-issuer`, `letsencrypt-staging`, and `letsencrypt-prod` ClusterIssuers
- `local-path-provisioner` as the default `standard` StorageClass, redirected to `STORAGE_PATH`
- Host-path storage under `~/.local/share/k8s-volumes`, owned by your user

Optional, each gated behind an env flag: GPU passthrough, monitoring (Prometheus + Grafana + Alertmanager), Ollama (local LLM inference), Hermes Agent.

---

## Contents

1. [Prerequisites](#prerequisites)
2. [Quick start](#quick-start)
3. [Local access: `/etc/hosts`](#local-access-etchosts)
4. [Going public: Let's Encrypt behind NAT](#going-public-lets-encrypt-behind-nat)
5. [GPU passthrough](#gpu-passthrough)
6. [Host maintenance: pause / resume](#host-maintenance-pause--resume)
7. [Configuration reference](#configuration-reference)
8. [Optional components](#optional-components)
9. [Shared resources](#shared-resources)
10. [Make targets](#make-targets)
11. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- **Docker — native, not the snap.** Use Docker CE from the official apt repo (or your distro's package), **not** `snap install docker`. The snap works for CPU-only clusters but **cannot do NVIDIA GPU passthrough** (see [GPU passthrough](#gpu-passthrough)). Save yourself the migration later and install native Docker up front. Docker must run without `sudo` (`sudo usermod -aG docker $USER && newgrp docker`).
- **Kind** — `brew install kind` or https://kind.sigs.k8s.io/docs/user/quick-start/#installation
- **kubectl** — https://kubernetes.io/docs/tasks/tools/
- **Helm** — required only for monitoring; optional otherwise
- **NVIDIA Container Toolkit** — only if you want GPU passthrough (see [GPU passthrough](#gpu-passthrough))
- **inotify limits raised** — Kind + Docker chew through the default quickly. Do this once:
  ```bash
  echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
  echo fs.inotify.max_user_instances=512  | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  ```

---

## Quick start

Everything is driven from a `.env` file. Copy the example, edit it, bring the cluster up:

```bash
make env          # copies .env.example → .env
$EDITOR .env      # set ACME_EMAIL at minimum (see below)
make up
```

In `.env`, the one **required** value is `ACME_EMAIL` (used by the Let's Encrypt ClusterIssuers). If you plan to serve public domains, also set `ACME_SELFCHECK_DOMAINS` — see [Going public](#going-public-lets-encrypt-behind-nat). Everything else has a sane default.

`make up` is **idempotent** — re-running it won't blow anything away, so it's safe to run after editing `.env`.

When it finishes it prints the Kind node IP. Use it for local name resolution (next section).

> **Note:** `.env` is gitignored — your real domains, email, and secrets stay local and never get committed. The examples in this README use placeholders like `example.com` and `you@example.com`; put your real values only in `.env`.

---

## Local access: `/etc/hosts`

The ingress hostnames need to resolve to the Kind node so you can reach your apps from the host. Let the helper manage `/etc/hosts` for you:

```bash
make hosts        # writes a managed block to /etc/hosts (needs sudo)
```

This syncs a marked block to the current node IP and leaves the rest of your `/etc/hosts` untouched. Re-run it any time the node IP changes (e.g. after a Docker restart). The hostnames come from the `HOSTS` variable plus any enabled component ingress hosts — set `HOSTS` in `.env` to match your projects:

```bash
HOSTS = example.com app.example.com api.example.org
```

To do it by hand instead, take the node IP `make up` printed and add a line:

```
<node-ip>  example.com app.example.com
```

---

## Going public: Let's Encrypt behind NAT

This is **the** pain point when self-hosting on a residential connection. Two separate problems, both solved here.

### 1. Forward router ports 80 and 443 to the host

Let's Encrypt's HTTP-01 challenge connects **from the public internet** to your domain on port 80. For that to reach your cluster, your router must port-forward:

- **TCP 80 → host:80** (required for HTTP-01 validation)
- **TCP 443 → host:443** (for serving HTTPS)

Your domain's DNS A record must point at your public IP. Some ISPs block inbound port 80 — if validation never succeeds, check that first. (This setup uses HTTP-01, so you do **not** need DNS-01 or to hand cert-manager your DNS provider credentials.)

### 2. The hairpin problem — why `ACME_SELFCHECK_DOMAINS` exists

Before cert-manager asks Let's Encrypt to validate, it runs an **in-cluster self-check**: it resolves your domain and tries to fetch the challenge token itself. On a home network your domain resolves to your **public** IP — and most consumer routers can't route a packet from inside the LAN back to their own public IP (this is "hairpin NAT" or "NAT loopback"). So the self-check hangs and certificate issuance sits **pending forever**, even though the *external* validation would succeed.

`ACME_SELFCHECK_DOMAINS` fixes this. Set it to the space-separated domains your ingress serves:

```bash
ACME_SELFCHECK_DOMAINS = example.com app.example.com
```

On `make up`, the setup script rewrites those names **inside CoreDNS** to point at the in-cluster ingress service (`ingress-nginx-controller.ingress-nginx.svc.cluster.local`). Now the self-check resolves and passes internally, while Let's Encrypt still validates externally over your port-80 forward. No hairpin, no DNS-01.

### 3. Pick the right issuer

| Issuer | Use case |
|---|---|
| `selfsigned-issuer` | Local dev, no internet required |
| `letsencrypt-staging` | Test the ACME pipeline without hitting rate limits |
| `letsencrypt-prod` | Public domains with real, trusted certs |

**Always test with `letsencrypt-staging` first.** Prod has a rate limit of 5 duplicate certs per domain per week — easy to burn through while debugging. Reference an issuer in your app's ingress:

```yaml
cert-manager.io/cluster-issuer: letsencrypt-staging
```

### 4. Don't re-issue certs on every recreate — `CERT_PERSIST`

`kind delete cluster` wipes etcd, so every issued certificate Secret dies with the cluster. On the next `make up`, cert-manager re-requests from Let's Encrypt — and a few `make recreate` cycles can blow through the prod rate limit.

Set `CERT_PERSIST=true` and the cluster saves your TLS certs + ACME account keys (to `STORAGE_PATH/cert-backup`, mode 0600) on `make down`, and restores them on `make up`. cert-manager then **adopts the existing valid certs and skips issuance** until a genuine renewal is due.

```bash
CERT_PERSIST = true
```

Enable this once you're issuing real `letsencrypt-prod` certs and expect to recreate the cluster. (You can also run it manually: `make certs-save` / `make certs-restore`.)

---

## GPU passthrough

> ### ⚠️ GPU passthrough requires **native** Docker — the Docker **snap cannot do it**
>
> The Canonical Docker snap (`snap install docker`) reaches GPUs only through its `gpu-2404` content interface, which on a normal system is wired to **Mesa, not the NVIDIA proprietary driver**. There is no NVIDIA driver content snap to connect it to (an apt-installed driver isn't a snap), so the snap **physically cannot inject NVML/libcuda** into containers — no amount of config fixes it. The snap also regenerates its `nvidia-container-runtime` config on every restart, fighting any edits.
>
> **Check which Docker you have:** if `docker info` shows `Docker Root Dir: /var/snap/docker/...`, you're on the snap and must migrate to native Docker first:
>
> ```bash
> make down                      # tear down cleanly while the daemon is healthy
> sudo snap remove --purge docker
> # install Docker CE from the official apt repo:
> #   https://docs.docker.com/engine/install/ubuntu/
> sudo usermod -aG docker $USER && newgrp docker
> make setup-gpu && make up
> ```
>
> Your registry images and PV data live on host bind-mounts under `STORAGE_PATH`, so they survive the migration.

### One-time host setup

With native Docker and `nvidia-container-toolkit` installed, run:

```bash
make setup-gpu      # configures Docker's nvidia runtime, then restarts Docker (needs sudo)
```

`make setup-gpu` detects your Docker flavor and writes both required settings — `default-runtime=nvidia` and `accept-nvidia-visible-devices-as-volume-mounts=true` — to the right files, then restarts Docker. Then bring the cluster up with the GPU enabled:

```bash
make up GPU_ENABLED=true OLLAMA_GPU=true
```

Or set `GPU_ENABLED=true` (and `OLLAMA_GPU=true` if using Ollama) in `.env`. Changing `GPU_ENABLED` on an existing cluster requires `make recreate`.

### How GPU reaches pods

Host Docker (`default-runtime=nvidia`) injects the driver into the Kind *node* — but pods run via the node's internal containerd, which defaults to `runc`. `make up` handles this automatically for GPU clusters: it drops the host's NVIDIA toolkit into each node, sets the node's containerd default runtime to `nvidia`, and deploys the device plugin so it can advertise `nvidia.com/gpu`. Verify:

```bash
kubectl get node homelab-control-plane -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'   # 1
```

(Replace `homelab` with your `CLUSTER_NAME` if you changed it.)

---

## Host maintenance: pause / resume

When you need the machine down — a GPU swap, a RAM upgrade, moving the box — **don't use `make down`**. Teardown deletes the Kind cluster, and deleting the cluster wipes etcd along with every Helm release installed into it. You'd be reinstalling all your projects afterwards.

`make pause` suspends the cluster instead:

```bash
make pause          # quiesce workloads, stop the node container
sudo poweroff       # ...do the hardware work...
make resume         # start the node, restore every workload
```

**What pause does**, in order:

1. Snapshots the replica count of every Deployment and StatefulSet outside `PAUSE_SKIP_NAMESPACES` to `STORAGE_PATH/.pause-state/`, along with the node IP.
2. Scales ingress to zero first, so nothing new arrives while the tiers behind it are shutting down.
3. Drains application Deployments.
4. Drains each `PAUSE_LAST` Deployment on its own, waiting for its pods to fully terminate — for workloads that own a database in a Deployment rather than a StatefulSet and need an uncontended window to checkpoint on `SIGTERM`.
5. Drains StatefulSets one at a time, waiting for each.
6. `docker stop`s the node and registry containers.

`make resume` reverses it: containers up, wait for the API server, re-verify GPU passthrough, then restore replicas datastores-first so backends are serving before ingress reopens.

The node's Docker restart policy is `on-failure`, so a clean pause means the cluster stays down across a host reboot until you run `make resume` — it won't come halfway up on its own.

**Two things pause does not do:**

- **It doesn't back up databases.** The pause is graceful, but graceful isn't a backup, and hardware work is exactly when you want one. Dump anything irreplaceable first.
- **It doesn't re-verify GPU hardware changes until resume.** GPU passthrough is wired into the node container at *creation* time via the `/var/run/nvidia-container-devices/all` sentinel mount. The nvidia runtime re-runs its injection hook on `docker start`, so a same-vendor card swap normally just works — `make resume` restarts the device plugin and confirms the node still advertises `nvidia.com/gpu`. If it reports that the node isn't advertising a GPU, the fix is `make recreate GPU_ENABLED=true`. Check driver support for a new card *before* you shut down: a card newer than your driver won't come back.

If Docker hands the node a different IP on restart, `make resume` says so — run `make hosts` to re-point `/etc/hosts`.

---

## Configuration reference

Copy `.env.example` to `.env` with `make env`. Every variable can also be exported or passed on the `make` command line — **command-line args override `.env`, which overrides the built-in defaults.**

### Core

| Variable | Default | Notes |
|---|---|---|
| `ACME_EMAIL` | (required) | Used in the Let's Encrypt ClusterIssuers |
| `ACME_SELFCHECK_DOMAINS` | (empty) | Space-separated public domains; rewritten in CoreDNS to fix the NAT hairpin self-check. See [Going public](#going-public-lets-encrypt-behind-nat) |
| `CERT_PERSIST` | `false` | Save/restore TLS certs + ACME keys across recreates to dodge prod rate limits |
| `CLUSTER_NAME` | `homelab` | |
| `REGISTRY_PORT` | `5000` | Registry at `localhost:5000` |
| `STORAGE_PATH` | `~/.local/share/k8s-volumes` | Host path for PV data, owned by `HOST_UID:HOST_GID` |
| `HOST_UID` / `HOST_GID` | current user | PV directories are chowned to this on creation |
| `HOSTS` | project hostnames | Space-separated names `make hosts` writes to `/etc/hosts` |
| `TEARDOWN_GRACE` | `60` | Seconds to drain namespaces on `make down` |
| `PAUSE_LAST` | (empty) | Space-separated `namespace/name` Deployments drained last on `make pause`, just before StatefulSets. See [Host maintenance](#host-maintenance-pause--resume) |
| `PAUSE_GRACE` | `120` | Seconds per workload drain and for `docker stop` on `make pause` |
| `PAUSE_SKIP_NAMESPACES` | control-plane namespaces | Namespaces left running through a pause |
| `RESUME_TIMEOUT` | `300` | Seconds to wait for the node and each workload on `make resume` |

### Optional components

| Variable | Default | Notes |
|---|---|---|
| `GPU_ENABLED` | `false` | GPU passthrough — requires native Docker + NVIDIA toolkit |
| `MONITORING` | `false` | Prometheus + Grafana + Alertmanager |
| `OLLAMA` | `false` | Local LLM inference — must be set at cluster creation time |
| `HERMES` | `false` | Hermes Agent — must be set at cluster creation time |

### Component version pinning

These control what gets installed. Pin them in `.env` so `make recreate` restores an identical stack:

| Variable | Default |
|---|---|
| `CERT_MANAGER_VERSION` | `v1.14.2` |
| `INGRESS_NGINX_VERSION` | `controller-v1.11.3` |
| `PROMETHEUS_CHART_VERSION` | (latest) |

After first installing monitoring, pin the Prometheus chart version so recreates land on the same chart:

```bash
helm list -A -o json | jq -r '.[] | .name + " " + .chart'
```

Copy the `kube-prometheus-stack-XX.X.X` value into `.env` as `PROMETHEUS_CHART_VERSION`.

---

## Optional components

Each component is off by default and gated by an env flag. `GPU_ENABLED`, `OLLAMA`, and `HERMES` change how the Kind node is built, so toggling them on an existing cluster requires `make recreate` (not just `make up`).

### GPU passthrough

NVIDIA GPU access for pods. See the dedicated [GPU passthrough](#gpu-passthrough) section — it needs native Docker and one-time host setup. Enable with `GPU_ENABLED=true` (set `OLLAMA_GPU=true` too if you want Ollama on the GPU).

### Monitoring (Prometheus + Grafana + Alertmanager)

A full kube-prometheus-stack for metrics, dashboards, and alerts.

```bash
make up MONITORING=true     # enable at cluster creation
make monitoring             # add to an existing cluster
make monitoring-down        # remove
```

Default Grafana password is `homelab` — override with `GRAFANA_PASSWORD` (the `.env.example` ships `changeme`; set your own). Alertmanager starts with a null receiver; for email alerts, edit the commented block in `resources/monitoring-values.yaml`. After install, pin `PROMETHEUS_CHART_VERSION` (see [version pinning](#component-version-pinning)).

### Ollama (local LLM inference)

Runs Ollama in-cluster, sharing model storage with a host Ollama install so you don't download models twice. `OLLAMA_DATA_PATH` defaults to `~/.ollama` (the same directory the native `ollama` binary uses) and is **bind-mounted into the Kind node at cluster creation time** — changing it requires `make recreate`.

```bash
make up OLLAMA=true GPU_ENABLED=false OLLAMA_GPU=false   # CPU-only
make up OLLAMA=true GPU_ENABLED=true  OLLAMA_GPU=true    # with GPU
make ollama                                              # add to existing cluster
make ollama-down                                         # remove (host model data untouched)
```

| Variable | Default | Notes |
|---|---|---|
| `OLLAMA_DATA_PATH` | `~/.ollama` | Shared with host Ollama; bind-mounted at cluster creation |
| `OLLAMA_MODEL` | `qwen2.5:7b-instruct-q6_K` | Pulled at pod startup; cached after |
| `OLLAMA_CONTEXT_LENGTH` | `65536` | Serving context window (Ollama defaults to 2048; Hermes needs ≥64K) |
| `OLLAMA_STORAGE` | `20Gi` | PV size for the mount |
| `OLLAMA_GPU` | `false` | Request `nvidia.com/gpu` in the pod |
| `OLLAMA_INGRESS_HOST` | (empty) | Hostname to expose via Ingress; empty = ClusterIP only |

In-cluster endpoint: `http://ollama.ollama.svc.cluster.local:11434`. With no ingress, reach it via port-forward:

```bash
kubectl port-forward -n ollama svc/ollama 11434:11434
```

### Hermes Agent

An agent service with an optional dashboard. Its data directory is **bind-mounted into the Kind node at cluster creation time** — you can't add Hermes retroactively without a recreate.

```bash
make up HERMES=true GPU_ENABLED=false OLLAMA=false       # create cluster with the mount
make recreate HERMES=true                                # or recreate an existing one
make hermes                                              # deploy Hermes onto the cluster
make hermes-down                                         # remove
```

| Variable | Default | Notes |
|---|---|---|
| `HERMES_DATA_PATH` | `~/.hermes` | Bind-mounted into the Kind node at cluster creation |
| `HERMES_DASHBOARD` | `true` | Enables the dashboard service |
| `HERMES_DASHBOARD_PORT` | `9119` | Dashboard is **ClusterIP only** — reach it via port-forward |
| `HERMES_API_SERVER_KEY` | (empty) | The Hermes `api_server` (port 8642) **refuses to start without a key** |

**The dashboard is port-forward only** — there's no node port for it. Forward to it:

```bash
kubectl port-forward -n hermes svc/hermes-dashboard 9119:9119
```

**Enabling the API server:** Hermes' `api_server` won't start unless `HERMES_API_SERVER_KEY` is set. Generate one and put it in `.env` (it's gitignored, so the secret stays local):

```bash
openssl rand -hex 32
```

```bash
HERMES_API_SERVER_KEY = <the generated value>
```

Leave it unset to keep the API server disabled. To expose the dashboard publicly with TLS, set `HERMES_DASHBOARD_INGRESS_HOST` and `HERMES_DASHBOARD_CLUSTER_ISSUER` (the `letsencrypt-*` issuers require the host to be publicly reachable — see [Going public](#going-public-lets-encrypt-behind-nat)).

To run Hermes against the in-cluster Ollama, point the `model` block in `~/.hermes/config.yaml` (bind-mounted, read live by the pod) at Ollama's OpenAI-compatible endpoint:

```yaml
model:
  default: qwen2.5:7b-instruct-q6_K
  provider: openai
  base_url: http://ollama.ollama.svc.cluster.local:11434/v1
  api_key: ollama        # Ollama ignores the value; any non-empty string works
  context_length: 65536  # must match OLLAMA_CONTEXT_LENGTH; Hermes needs >=64K
```

Reload it with `kubectl rollout restart deploy/hermes -n hermes`.

---

## Shared resources

### Registry

Push from your host, pull from inside the cluster — same address either way:

```bash
docker push localhost:5000/my-image:tag
```

```yaml
image: localhost:5000/my-image:tag
```

### Storage

`local-path-provisioner` is redirected to `STORAGE_PATH` on the host. PVCs on the `standard` StorageClass provision there automatically, owned by `HOST_UID:HOST_GID`. For explicit host-path volumes, `STORAGE_PATH` is mounted to `/mnt/k8s-volumes` inside the node — create a subdirectory before deploying so projects don't collide:

```bash
mkdir -p ~/.local/share/k8s-volumes/my-project
```

### ClusterIssuers

`selfsigned-issuer` (local dev), `letsencrypt-staging` (ACME testing), `letsencrypt-prod` (public, trusted certs). See [Going public](#going-public-lets-encrypt-behind-nat).

---

## Make targets

```bash
make env             # Copy .env.example → .env (first-time only)
make up              # Create cluster + all enabled services (idempotent)
make hosts           # Sync /etc/hosts to the current node IP (needs sudo)
make pause           # Quiesce workloads + stop the node (host maintenance, reversible)
make resume          # Restart the node and restore workloads after a pause
make down            # Drain optional namespaces, destroy cluster + registry
make recreate        # down then up (required when changing GPU_ENABLED / HERMES / OLLAMA)
make setup-gpu       # One-time NVIDIA host config for GPU passthrough (needs sudo)
make certs-save      # Back up TLS certs + ACME keys (auto via CERT_PERSIST)
make certs-restore   # Restore them into a fresh cluster
make monitoring      # Install/upgrade monitoring on an existing cluster
make monitoring-down # Remove the monitoring stack
make ollama          # Deploy/upgrade Ollama on an existing cluster
make ollama-down     # Remove Ollama (host model data preserved)
make hermes          # Deploy/upgrade Hermes on an existing cluster
make hermes-down     # Remove Hermes
make clean           # Prompt, then delete STORAGE_PATH (all PV data) on the host
make status          # Show cluster/node/context state
make fix-context     # Repair kubectl context if it breaks
make logs            # Dump control-plane container logs
make help            # Full variable reference
```

---

## Troubleshooting

**kubectl context broke after a Docker restart**

```bash
make fix-context
```

**Certificate stuck `pending` / never issues**

Almost always one of the NAT problems. Walk the chain:
1. Is `ACME_SELFCHECK_DOMAINS` set to your domains in `.env`? Without it, the in-cluster self-check stalls on hairpin NAT and issuance never starts. See [Going public](#going-public-lets-encrypt-behind-nat).
2. Are router ports 80/443 forwarded to the host, and does your domain's DNS point at your public IP? Let's Encrypt validates from outside.
3. Is your ISP blocking inbound port 80? Test from an external network.
4. Debugging the flow? Use `letsencrypt-staging`, not `letsencrypt-prod`, so you don't burn the rate limit.

Inspect what cert-manager is doing:

```bash
kubectl describe certificate -A
kubectl describe challenge -A
```

**GPU not detected / preflight fails**

The preflight checks `nvidia-smi`, `nvidia-container-toolkit`, Docker's default runtime, and `accept-nvidia-visible-devices-as-volume-mounts`. First confirm you're on **native Docker, not the snap** (`docker info | grep "Docker Root Dir"` — `/var/snap/...` means snap, which can't do GPU; see [GPU passthrough](#gpu-passthrough)). Then run `make setup-gpu`.

**Order matters** when reconfiguring Docker: tear the cluster down *before* restarting Docker. A daemon restart under a live cluster strands the `docker-proxy` processes holding ports 80/443/8888/5000, which then block the next `make up` with "address already in use".

```bash
make down   # FIRST, while the daemon is healthy — nothing to orphan
make setup-gpu
make up
```

To skip the GPU entirely: `make up GPU_ENABLED=false OLLAMA=false`.

**"address already in use" on ports 80 / 443 / 8888 / 5000**

Stranded `docker-proxy` processes from a Docker restart under a live cluster. Free them (note `fuser -k` kills *whatever* holds the port — make sure nothing else legitimately uses these):

```bash
sudo fuser -k 80/tcp 443/tcp 8888/tcp 5000/tcp
```

**Cluster exists but the API server is unresponsive**

`make up` detects this and deletes/recreates the cluster automatically — just re-run it.

**Hermes or Ollama data not visible in the pod**

The Kind node needs the bind mount from *cluster creation*. If you enabled the component after the fact:

```bash
make recreate HERMES=true                 # Option A: recreate with the mount
# Option B: symlink into the existing storage mount, no recreate
ln -s ~/.hermes ~/.local/share/k8s-volumes/hermes
make hermes HERMES_DATA_PATH=~/.local/share/k8s-volumes/hermes
```

**Delete all PV data on the host**

```bash
make clean   # prompts for confirmation before deleting STORAGE_PATH
```
