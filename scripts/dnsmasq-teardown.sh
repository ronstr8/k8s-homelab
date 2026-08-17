#!/bin/bash
# Remove the homelab split-horizon DNS drop-in and stop serving LAN DNS.
#
# Leaves the dnsmasq package installed (harmless, and NetworkManager may want
# dnsmasq-base) and leaves systemd-resolved alone — setup never touched it.
#
# Before running: any client still pointed at this host for DNS will lose name
# resolution. Repoint them first, or make sure they list a public resolver as a
# secondary.
#
# Usage:  make dnsmasq-down     (re-execs itself with sudo)
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "🔐 dnsmasq teardown needs root — re-running with sudo..."
  exec sudo --preserve-env=PATH bash "$0" "$@"
fi

CONF="/etc/dnsmasq.d/homelab.conf"

echo "🧹 Removing homelab dnsmasq config"

if [[ -f "${CONF}" ]]; then
  rm -f "${CONF}"
  echo "   ✅ removed ${CONF}"
else
  echo "   ℹ️  ${CONF} not present"
fi

# With the drop-in gone, a still-running dnsmasq would fall back to the stock
# config and bind 0.0.0.0:53 — an open resolver on the LAN. Stop it instead.
if systemctl is-enabled --quiet dnsmasq 2>/dev/null || systemctl is-active --quiet dnsmasq 2>/dev/null; then
  systemctl disable --now dnsmasq >/dev/null 2>&1 || true
  echo "   ✅ dnsmasq stopped and disabled"
else
  echo "   ℹ️  dnsmasq was not running"
fi

# systemd-resolved should still hold the stub listeners; setup never changed it.
if ss -lntu "sport = :53" 2>/dev/null | grep -q "127.0.0.53"; then
  echo "   ✅ systemd-resolved still serving 127.0.0.53 — host resolution intact"
else
  echo "   ⚠️  systemd-resolved is not listening on 127.0.0.53. Check:" >&2
  echo "      systemctl status systemd-resolved" >&2
fi

echo ""
echo "✅ Done. Repoint any LAN clients that still list this host for DNS."
