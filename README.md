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
4. [LAN access: `make dnsmasq`](#lan-access-make-dnsmasq)
5. [Going public: Let's Encrypt behind NAT](#going-public-lets-encrypt-behind-nat)
6. [GPU passthrough](#gpu-passthrough)
7. [Host maintenance: pause / resume](#host-maintenance-pause--resume)
8. [Configuration reference](#configuration-reference)
9. [Optional components](#optional-components)
10. [Shared resources](#shared-resources)
11. [Make targets](#make-targets)
12. [Troubleshooting](#troubleshooting)

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

## LAN access: `make dnsmasq`

`make hosts` only fixes **this** machine. Every *other* device in the house — laptops, phones, tablets — resolves your ingress hostnames through real public DNS, gets your **public WAN IP**, and sends the packet to the router. Most consumer routers refuse to route that back inside to themselves, so the request dies even though the server is in the next room. This is the same [hairpin NAT](#2-the-hairpin-problem--why-acme_selfcheck_domains-exists) problem `ACME_SELFCHECK_DOMAINS` solves for cert-manager, just hitting a different audience.

If your router exposes **DNS host entries** (sometimes "Local DNS", "DNS Hosts", "Address Reservation + hostname"), use those — one setting, fixes every device. Many ISP-supplied gateways (Spectrum/Sercomm, in particular) do not. When that's the case, serve DNS from the cluster host itself:

```bash
make dnsmasq        # installs + configures dnsmasq on this host (needs sudo)
```

It answers your ingress hostnames with **this host's LAN IP** and forwards everything else upstream. Names come from `HOSTS` (the same list `make hosts` uses) unless you override `DNSMASQ_DOMAINS`:

```bash
DNSMASQ_LISTEN_IP  = 192.168.1.222   # empty = autodetect from the default route
DNSMASQ_DOMAINS    =                 # empty = reuse HOSTS
DNSMASQ_UPSTREAM   = 1.1.1.1 8.8.8.8
DNSMASQ_LAN_DOMAIN = lan             # keep the router authoritative for its own domain
```

### Why this points somewhere different than `make hosts`

They answer with **deliberately different addresses**, because different resolvers consume them. Do not "fix" one to match the other:

| | Answers with | Consumed by |
|---|---|---|
| `make hosts` | Kind **node** IP (`172.x`) | This host only — browsers and `curl` on the machine running the cluster |
| `make dnsmasq` | **Host's LAN** IP (`192.168.x`) | Other machines, which must reach the host's published ports |

The in-cluster ACME HTTP-01 self-check is *not* served by `/etc/hosts` — pods
resolve through CoreDNS, where `ACME_SELFCHECK_DOMAINS` installs a rewrite to
the ingress Service. See `scripts/update-hosts.sh`.

**One name is special: this host's own.** If a hostname in `HOSTS` is also this
machine's hostname, `make hosts` gives it the **LAN IP**, not the node IP.
Handing the machine's own name to a container breaks anything that resolves the
host by name and expects to find the host — most visibly `ssh -Y` with
`X11UseLocalhost no`, which sets `DISPLAY=<fqdn>:10.0`; the X client then dials
the *node* on port 6010, where sshd is not listening, and forwarding dies. The
LAN IP serves both roles: sshd is on it, and so is the published ingress.

### Pointing clients at it

If the router can't hand out a custom DNS server either, set it per-device. List a public resolver **second** so the internet still works when this host is down — you just lose the homelab names until it's back:

```powershell
# Windows (elevated); WSL2 inherits this unless wsl.conf sets generateResolvConf=false
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ServerAddresses 192.168.1.222,1.1.1.1
```

```bash
# Linux / NetworkManager
nmcli con mod <connection> ipv4.dns "192.168.1.222 1.1.1.1" ipv4.ignore-auto-dns yes
```

### Safety properties

The generated `/etc/dnsmasq.d/homelab.conf` is deliberately narrow:

- **Binds only the LAN address.** systemd-resolved keeps `127.0.0.53`/`127.0.0.54`, so the host's own resolver stack is untouched and needs no changes.
- **Defines no `dhcp-range`.** dnsmasq cannot start answering DHCP and fight the router for it. Don't add one.
- **Uses `no-resolv`** with explicit upstreams — forwarding to `/etc/resolv.conf` would point back at systemd-resolved and loop.
- **Uses `no-hosts`.** dnsmasq reads `/etc/hosts` by default and prefers those entries over its own `address=` lines. Since `make hosts` deliberately maps the *same names* to the Kind node IP, omitting this makes dnsmasq serve LAN clients a `172.x` address they cannot route to. The two layers must stay independent.
- **Leaves your DDNS hostname alone**, so it keeps resolving to the real WAN IP for off-network clients.

**Reserve the host's IP on the router.** The config hardcodes it; if the address moves, dnsmasq won't start and every client pointed at it loses DNS. `make dnsmasq` notes when the address arrives via DHCP — but a router-side reservation is delivered over DHCP too and looks identical from the host, so that note is a prompt to confirm, not evidence the address is unreserved.

Undo with `make dnsmasq-down` (repoint clients first).

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
| `OLLAMA_MODEL` | `gemma3:12b` | Pulled at pod startup; cached after |
| `OLLAMA_CONTEXT_LENGTH` | `32768` | Serving context window (Ollama defaults to 2048) — see [Sizing](#sizing-the-context-window) |
| `OLLAMA_STORAGE` | `64Gi` | PV size for the mount; see [Resizing](#resizing-the-model-cache) |
| `OLLAMA_GPU` | `false` | Request `nvidia.com/gpu` in the pod |
| `OLLAMA_INGRESS_HOST` | (empty) | Hostname to expose via Ingress; empty = ClusterIP only |

In-cluster endpoint: `http://ollama.ollama.svc.cluster.local:11434`. With no ingress, reach it via port-forward:

```bash
kubectl port-forward -n ollama svc/ollama 11434:11434
```

#### Sizing the context window

`OLLAMA_CONTEXT_LENGTH` is a **server-wide ceiling**, and the KV cache it implies is allocated per loaded model. It is the single easiest way to run a GPU out of VRAM, so budget it against the card rather than picking the model's advertised maximum.

Worked example — the default `gemma3:12b` (Q4_K_M) on a 16GB card:

| | |
|---|---|
| weights | ~8.1GB |
| vision tower (SigLIP) | ~0.9GB |
| KV cache @ 32K | ~2.2GB |
| compute buffers | ~1GB |
| **total** | **~12.2GB of 16.3GB** |

At 64K the KV cache roughly doubles to ~4.3GB and the total lands near 14.3GB — it still fits, but a second model or a stray allocation will push layers onto the CPU and collapse throughput. Hence the 32K default.

That KV figure already assumes sliding-window attention: Gemma 3 makes only every sixth layer global, so 40 of its 48 layers cap out at a 1024-token window. Ollama applies this automatically (≥0.9). Without it the same 64K cache would want ~24GB.

Clients that need less should send a smaller **per-request** `num_ctx` rather than relying on the server default — logodal pins `num_ctx: 4096` for exactly this reason, since its prompts peak around 400 tokens.

#### Resizing the model cache

`OLLAMA_STORAGE` sizes a **statically provisioned** PV/PVC pair (`storageClassName: ""`). Kubernetes only allows in-place resize on *dynamically* provisioned claims backed by a StorageClass with `allowVolumeExpansion: true`, so changing `OLLAMA_STORAGE` on an existing cluster can't be applied by `make ollama` — it would fail with:

```
persistentvolumeclaims "ollama-models" is forbidden: only dynamically
provisioned pvc can be resized and the storageclass that provisions
the pvc must support resize
```

`make ollama` detects the mismatch up front and prints the fix rather than failing partway through. To resize, recreate the pair:

```bash
kubectl scale deploy/ollama -n ollama --replicas=0
kubectl wait --for=delete pod -l app=ollama -n ollama --timeout=120s
kubectl delete pvc ollama-models -n ollama
kubectl delete pv ollama-models-pv
make ollama
```

**Your models are not deleted.** The PV is `hostPath` with `persistentVolumeReclaimPolicy: Retain`; the files live at `STORAGE_PATH/ollama` on the host and survive the PV/PVC teardown. The pod re-binds to the same directory and finds its existing cache.

Note that a hostPath PV **never enforces** its capacity — the number is bookkeeping, and the real limit is free space on the filesystem backing `STORAGE_PATH`. Keeping it honest still matters: it's what you'll read when deciding whether another model fits.

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
  default: hermes3:8b
  provider: openai-api
  base_url: http://ollama.ollama.svc.cluster.local:11434/v1
  api_key: ollama        # Ollama ignores the value; any non-empty string works
  context_length: 32768  # must not exceed OLLAMA_CONTEXT_LENGTH
```

Hermes loads its own model rather than `OLLAMA_MODEL`, but it shares the server's context ceiling — asking for more than `OLLAMA_CONTEXT_LENGTH` gets silently truncated.

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
make dnsmasq         # Serve LAN DNS so other machines resolve by name (needs sudo)
make dnsmasq-down    # Stop serving LAN DNS
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

**"Everything is running but nothing is reachable" — triage before touching the cluster**

When services go dark after a power cut, router reboot, or ISP event, the cluster is usually the *last* thing at fault. Resist `make recreate` — it destroys etcd and every dependent project's Helm release to fix a problem that is nearly always in the network. `make pause`/`make resume` are the reversible tools; neither helps if the cluster was healthy to begin with.

Work outward from the host, and stop at the first failure:

```bash
# 1. Is the cluster actually broken? (usually: no)
kubectl get nodes && kubectl get pods -A

# 2. Does the ingress serve locally? 308 or 200 = healthy
curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: example.com' https://127.0.0.1/

# 3. Does it serve on the LAN address other machines use?
curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: example.com' https://<host-lan-ip>/

# 4. Does public DNS still point at your current WAN IP?
dig +short @1.1.1.1 example.com ; curl -s https://api.ipify.org

# 5. Is inbound actually arriving? Test from OUTSIDE the network —
#    phone on cellular, or any external host. Testing from inside proves nothing.
```

Things that have actually caused this, in rough order of likelihood:

- **DNS TTL after a WAN IP change.** The modem re-registers on power-up and the ISP hands out a different address. DDNS updates promptly, but resolvers worldwide cache the old record for the full TTL — an hour on a default 3600s record. Nothing is broken; it heals itself. Check the TTL before assuming otherwise: `dig +noall +answer @1.1.1.1 yourhost.example.com`.
- **Hairpin NAT.** External clients work, LAN clients don't. See [LAN access](#lan-access-make-dnsmasq). Diagnostic: from the host, connect to your own **public** IP — if that times out while an external client succeeds, hairpin is off, and only name resolution needs fixing.
- **Router config reset.** Port forwards, DHCP reservations, and admin passwords can all revert on a hard power loss. Verify the forwards *and* that they target the host's current IP.
- **Wi-Fi power save on the host.** Symptom is asymmetric latency: the host pings the gateway in ~2ms, but inbound connections from LAN clients take 30–70ms because the NIC sleeps between beacons. Badly wrong for a machine serving a cluster:
  ```bash
  iwconfig <iface> | grep -i 'power management'   # want: off
  nmcli con modify <connection> 802-11-wireless.powersave 2 && nmcli con up <connection>
  ```
  Check channel congestion too (`nmcli dev wifi list` — count BSSIDs sharing your channel). Wire the host if you can; it moots all of this.

**Browser forces HTTPS on a plain-HTTP port and fails**

The ingress sends `Strict-Transport-Security: max-age=31536000; includeSubDomains`. That pins **every** subdomain of your domain to HTTPS in the browser for a year — and HSTS ignores port, so `http://host.example.com:8188` gets silently upgraded to `https://` and dies against any service not speaking TLS.

Reach it by raw IP (`http://192.168.1.222:8188`) — HSTS is keyed to hostname, so an IP sidesteps it. Clearing the pin at `chrome://net-internals/#hsts` doesn't stick; it re-pins on the next visit to any HTTPS host in the domain. The real fix is to put the service behind the ingress with its own hostname and certificate.

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
