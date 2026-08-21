#!/bin/bash
# LAN-facing split-horizon DNS, so other machines in the house can reach the
# cluster by hostname.
#
# The problem it solves: the ISP gateway (Spectrum/Sercomm) exposes neither DNS
# host entries nor NAT loopback. A laptop resolving moor.fazigu.org gets the
# public WAN IP from real DNS, sends the packet to the router, and the router
# refuses to hairpin it back inside — so the request dies even though the server
# is ten feet away. Answering those names locally keeps the traffic on the LAN
# and never involves the router at all.
#
# ── This is NOT the same thing as `make hosts` ───────────────────────────────
# They point at deliberately different addresses, because they serve different
# resolvers:
#
#   make hosts     → /etc/hosts on THIS host  → the Kind NODE IP (172.x.x.x)
#                    Consumed by this host only: browsers and curl on the
#                    machine running the cluster. (cert-manager's in-cluster
#                    self-check does NOT read this file — pods resolve through
#                    CoreDNS, where ACME_SELFCHECK_DOMAINS installs a rewrite to
#                    the ingress Service.) One exception: a name in HOSTS that
#                    is this host's OWN name gets the LAN IP, not the node IP —
#                    see scripts/update-hosts.sh.
#
#   make dnsmasq   → dnsmasq on the LAN IP    → this host's LAN IP (192.168.x.x)
#                    Consumed by other machines, which must arrive at the host's
#                    published ports 80/443/8888.
#
# Changing either to match the other breaks the other's use case. Keep them split.
#
# Safety properties, all deliberate:
#   - Binds ONLY the LAN address. systemd-resolved keeps 127.0.0.53/127.0.0.54,
#     so the host's own resolver stack is untouched.
#   - Defines no dhcp-range, so dnsmasq cannot start answering DHCP and fight
#     the router for it. Do not add one.
#   - Uses no-resolv with explicit upstreams. Forwarding to /etc/resolv.conf
#     would point back at systemd-resolved and create a resolution loop.
#   - Uses no-hosts. dnsmasq reads /etc/hosts by default and prefers those
#     entries over its own address= lines — which would make it serve the Kind
#     node IP that `make hosts` puts there, unreachable from any other machine.
#
# Usage:  make dnsmasq        (re-execs itself with sudo)
set -euo pipefail

# ── Re-exec as root ──────────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
  echo "🔐 dnsmasq setup needs root — re-running with sudo..."
  exec sudo --preserve-env=DNSMASQ_LISTEN_IP,DNSMASQ_DOMAINS,DNSMASQ_UPSTREAM,DNSMASQ_LAN_DOMAIN,HOSTS,OLLAMA_INGRESS_HOST,HERMES_DASHBOARD_INGRESS_HOST,PATH bash "$0" "$@"
fi

CONF="/etc/dnsmasq.d/homelab.conf"

# LAN address to bind and to answer with. Autodetected from the default route.
LISTEN_IP="${DNSMASQ_LISTEN_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')}"

# Names to answer locally. Defaults to the same HOSTS list `make hosts` uses,
# plus the enabled components' ingress hosts — mirroring update-hosts.sh, so the
# two targets cover the same names. An explicit DNSMASQ_DOMAINS is used verbatim.
DOMAINS="${DNSMASQ_DOMAINS:-}"
if [[ -z "${DOMAINS}" ]]; then
  DOMAINS="${HOSTS:-}"
  [[ -n "${OLLAMA_INGRESS_HOST:-}" ]] && DOMAINS="${DOMAINS} ${OLLAMA_INGRESS_HOST}"
  [[ -n "${HERMES_DASHBOARD_INGRESS_HOST:-}" ]] && DOMAINS="${DOMAINS} ${HERMES_DASHBOARD_INGRESS_HOST}"
  # Deliberately not mirroring update-hosts.sh's hardcoded grafana.example.com:
  # a placeholder domain is harmless in /etc/hosts but this resolver answers the
  # whole LAN. Set MONITORING's real hostname via DNSMASQ_DOMAINS if you need it.
fi

# Upstream resolvers for everything else.
UPSTREAM="${DNSMASQ_UPSTREAM:-1.1.1.1 8.8.8.8}"

# Router's local domain, kept authoritative on the router itself.
LAN_DOMAIN="${DNSMASQ_LAN_DOMAIN:-}"

echo "🌐 dnsmasq split-horizon DNS setup"
echo "=================================="

# ── Validate inputs ──────────────────────────────────────────────────────────
if [[ -z "${LISTEN_IP}" ]]; then
  echo "❌ Could not autodetect the LAN IP. Set DNSMASQ_LISTEN_IP in .env." >&2
  exit 1
fi
if [[ -z "${DOMAINS}" ]]; then
  echo "❌ No domains to serve. Set HOSTS (or DNSMASQ_DOMAINS) in .env." >&2
  echo "   These are the names LAN clients should resolve to this host." >&2
  exit 1
fi
if ! ip -4 addr show | grep -qw "${LISTEN_IP}"; then
  echo "❌ ${LISTEN_IP} is not configured on any interface." >&2
  exit 1
fi
echo "   📍 Listening on ${LISTEN_IP}"
echo "   ⬆️  Upstream: ${UPSTREAM}"

# ── Refuse if something else already owns port 53 on that address ────────────
if ss -lntu "sport = :53" 2>/dev/null | grep -qE "(^|[^0-9.])(${LISTEN_IP}|0\.0\.0\.0|\*):53"; then
  if ! systemctl is-active --quiet dnsmasq; then
    echo "❌ Something other than dnsmasq already holds ${LISTEN_IP}:53." >&2
    ss -lntup "sport = :53" >&2 || true
    exit 1
  fi
fi

# ── Note when the LAN address arrives via DHCP ───────────────────────────────
# The config hardcodes LISTEN_IP; if the address moves, dnsmasq fails to start
# and every client pointed at it loses DNS. bind-dynamic survives the interface
# flapping, but not the address actually changing.
#
# This detects only that the address was DHCP-assigned. A router-side
# reservation is still delivered over DHCP and is indistinguishable from here,
# so this cannot tell reserved from unreserved. It's a prompt to confirm, not a
# claim that the address is unreserved.
if ip -4 addr show | grep -w "${LISTEN_IP}" | grep -q dynamic; then
  echo "   ℹ️  ${LISTEN_IP} arrives via DHCP. If it's reserved on the router,"
  echo "      nothing to do — that isn't visible from this host."
fi

# ── Install ──────────────────────────────────────────────────────────────────
# Stage the config before installing so dnsmasq never starts unconfigured
# (an unconfigured dnsmasq binds 0.0.0.0:53 and answers the whole LAN).
mkdir -p /etc/dnsmasq.d

echo "🛠️  Writing ${CONF}"
{
  echo "# Managed by scripts/dnsmasq-setup.sh — edits will be overwritten."
  echo "# Split-horizon DNS: the ISP gateway offers no DNS host entries and no"
  echo "# NAT loopback, so these names must be answered on the LAN side."
  echo
  echo "# Bind only the LAN address; systemd-resolved keeps 127.0.0.53/.54."
  echo "# bind-dynamic (not bind-interfaces) survives the interface going down."
  echo "listen-address=${LISTEN_IP}"
  echo "bind-dynamic"
  echo
  echo "# No dhcp-range anywhere in this file: dnsmasq will NOT serve DHCP."
  echo "# The router keeps that role. Do not add one."
  echo
  echo "# no-resolv is required — /etc/resolv.conf points at systemd-resolved,"
  echo "# and forwarding there would loop."
  echo "no-resolv"
  for u in ${UPSTREAM}; do echo "server=${u}"; done
  # if/fi rather than `[[ ]] &&` — an unset LAN_DOMAIN would make the AND-list
  # return non-zero, which is a needless hazard inside a redirected group.
  if [[ -n "${LAN_DOMAIN}" ]]; then
    echo "server=/${LAN_DOMAIN}/$(ip -4 route show default | awk '{print $3; exit}')"
  fi
  echo
  echo "domain-needed"
  echo "bogus-priv"
  echo "cache-size=1000"
  echo
  echo "# Do NOT read /etc/hosts. That file deliberately maps these same names to"
  echo "# the Kind NODE IP (172.x), which only this host can route to. dnsmasq"
  echo "# serves /etc/hosts entries in preference to the address= lines below, so"
  echo "# without this it hands LAN clients a node IP they cannot reach. The two"
  echo "# layers must stay independent - see the header of"
  echo "# scripts/dnsmasq-setup.sh."
  echo "no-hosts"
  echo
  echo "# Local overrides. In dnsmasq, address=/example.com/IP also matches"
  echo "# every subdomain of example.com."
  for d in ${DOMAINS}; do echo "address=/${d}/${LISTEN_IP}"; done
} > "${CONF}"
chmod 644 "${CONF}"

if ! command -v dnsmasq &>/dev/null || ! dpkg -l dnsmasq 2>/dev/null | grep -q '^ii'; then
  echo "📦 Installing dnsmasq..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq
fi

# Ubuntu's /etc/dnsmasq.conf normally ends with the conf-dir line; without it
# our drop-in is silently ignored and dnsmasq binds everything.
if ! grep -qE '^\s*conf-dir=/etc/dnsmasq\.d' /etc/dnsmasq.conf 2>/dev/null; then
  echo "conf-dir=/etc/dnsmasq.d/,*.dpkg-dist,*.dpkg-old,*.dpkg-new" >> /etc/dnsmasq.conf
  echo "   ➕ added missing conf-dir to /etc/dnsmasq.conf"
fi

echo "🧪 Validating config..."
dnsmasq --test

echo "🔄 Starting dnsmasq..."
systemctl enable --now dnsmasq >/dev/null 2>&1 || true
systemctl restart dnsmasq
sleep 1

# ── Verify ───────────────────────────────────────────────────────────────────
if ! systemctl is-active --quiet dnsmasq; then
  echo "❌ dnsmasq failed to start:" >&2
  systemctl status dnsmasq --no-pager -l >&2 || true
  exit 1
fi

# It must own the LAN address and must NOT have taken the resolved stubs.
if ss -lntu "sport = :53" 2>/dev/null | grep -q "127.0.0.53"; then
  echo "   ✅ systemd-resolved still holds 127.0.0.53"
fi

_fail=0
echo ""
echo "🔎 Resolution checks (each must answer ${LISTEN_IP}):"
for d in ${DOMAINS}; do
  _got="$(dig +short +time=2 +tries=1 "@${LISTEN_IP}" "${d}" A 2>/dev/null | tail -1)"
  if [[ "${_got}" == "${LISTEN_IP}" ]]; then
    printf '   ✅ %-28s %s\n' "${d}" "${_got}"
  else
    printf '   ❌ %-28s %s\n' "${d}" "${_got:-<no answer>}"
    _fail=1
  fi
done

# Upstream must still work, or we've built a resolver that only knows the homelab.
_up="$(dig +short +time=2 +tries=1 "@${LISTEN_IP}" github.com A 2>/dev/null | tail -1)"
if [[ -n "${_up}" && "${_up}" != "${LISTEN_IP}" ]]; then
  echo "   ✅ upstream resolution works (github.com → ${_up})"
else
  echo "   ❌ upstream resolution broken (github.com → ${_up:-<no answer>})"
  _fail=1
fi

echo ""
if [[ "${_fail}" -eq 0 ]]; then
  echo "✅ dnsmasq serving ${LISTEN_IP}:53."
  echo "   Point LAN clients at ${LISTEN_IP} for DNS. If the router won't hand out"
  echo "   a custom DNS server, set it per-device:"
  echo "     Windows:  Set-DnsClientServerAddress -InterfaceAlias 'Wi-Fi' -ServerAddresses ${LISTEN_IP},1.1.1.1"
  echo "     Linux:    nmcli con mod <name> ipv4.dns '${LISTEN_IP} 1.1.1.1' ipv4.ignore-auto-dns yes"
  echo "   Listing a public resolver second keeps the internet alive if this host"
  echo "   is down — you just lose the homelab overrides until it returns."
else
  echo "⚠️  dnsmasq is running but some checks failed (see above)." >&2
  exit 1
fi
