#!/bin/bash
# Save / restore cert-manager-issued TLS certs + ACME account keys across cluster
# recreates. `kind delete cluster` wipes etcd, so every issued certificate Secret
# dies with the cluster; on the next deploy cert-manager re-requests from Let's
# Encrypt and hits prod rate limits (5 duplicate certs/week per domain).
#
# Restoring the Secrets before the apps' Certificates reconcile lets cert-manager
# adopt the existing valid certs and skip issuance entirely (until genuine renewal).
#
# Usage:  cert-persist.sh save      (run while the old cluster is still up)
#         cert-persist.sh restore   (run after cert-manager + ClusterIssuers are ready)
set -euo pipefail

MODE="${1:-}"
STORAGE_PATH="${STORAGE_PATH:-${HOME}/.local/share/k8s-volumes}"
CERT_BACKUP_DIR="${CERT_BACKUP_DIR:-${STORAGE_PATH}/cert-backup}"

reachable() { kubectl cluster-info --request-timeout=5s &>/dev/null 2>&1; }

save() {
  if ! reachable; then echo "🔐 cert-persist: no reachable cluster — nothing to save."; return 0; fi
  # Names of the ACME account-key Secrets referenced by the ClusterIssuers
  # (they live in the cert-manager namespace).
  local acme_names
  acme_names="$(kubectl get clusterissuer -o jsonpath='{range .items[*]}{.spec.acme.privateKeySecretRef.name}{"\n"}{end}' 2>/dev/null | sort -u | grep -v '^$' || true)"

  # Only write if there's actually something to save. An empty save (e.g. tearing
  # down a fresh cluster before any cert was issued) must NOT create or clobber an
  # existing backup — python skips mkdir/write entirely when no matches are found.
  kubectl get secret -A -o json \
    | CERT_BACKUP_DIR="${CERT_BACKUP_DIR}" ACME_NAMES="${acme_names}" python3 - <<'PY'
import json, os, sys
backup = os.environ["CERT_BACKUP_DIR"]
acme = set(filter(None, os.environ.get("ACME_NAMES", "").splitlines()))
data = json.load(sys.stdin)

matches = []
for s in data.get("items", []):
    md = s.get("metadata", {})
    ns, name = md.get("namespace", ""), md.get("name", "")
    ann = md.get("annotations", {}) or {}
    typ = s.get("type", "")
    is_cert = typ == "kubernetes.io/tls" and "cert-manager.io/certificate-name" in ann
    is_acme = ns == "cert-manager" and name in acme
    if is_cert or is_acme:
        matches.append((s, md, ns, name, is_cert))

if not matches:
    print("🔐 cert-persist: no cert-manager certs/ACME secrets present — "
          "nothing to save (existing backup left intact).")
    sys.exit(0)

os.makedirs(backup, exist_ok=True)
os.chmod(backup, 0o700)
print(f"🔐 cert-persist: saving {len(matches)} secret(s) to {backup}")
for s, md, ns, name, is_cert in matches:
    # Strip cluster-specific / volatile fields so it re-applies into a fresh cluster.
    for k in ("resourceVersion", "uid", "creationTimestamp", "generation",
              "ownerReferences", "managedFields", "selfLink"):
        md.pop(k, None)
    s.pop("status", None)
    s["metadata"] = md
    fn = os.path.join(backup, f"{ns}__{name}.json")
    with open(fn, "w") as f:
        json.dump(s, f)
    os.chmod(fn, 0o600)
    print(f"   💾 {ns}/{name} ({'cert' if is_cert else 'acme-account'})")
print(f"✅ cert-persist: saved {len(matches)} secret(s)")
PY
}

restore() {
  if ! reachable; then echo "🔐 cert-persist: no reachable cluster — skipping restore."; return 0; fi
  if [[ ! -d "${CERT_BACKUP_DIR}" ]]; then
    echo "🔐 cert-persist: no backup at ${CERT_BACKUP_DIR} — nothing to restore."; return 0
  fi
  shopt -s nullglob
  local files=("${CERT_BACKUP_DIR}"/*.json)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "🔐 cert-persist: backup empty — nothing to restore."; return 0
  fi

  echo "🔐 cert-persist: restoring ${#files[@]} secret(s) from ${CERT_BACKUP_DIR}"
  local restored=0 f ns name
  for f in "${files[@]}"; do
    read -r ns name < <(python3 -c 'import json,sys;m=json.load(open(sys.argv[1]))["metadata"];print(m.get("namespace",""), m.get("name",""))' "${f}")
    [[ -n "${ns}" ]] || continue
    kubectl get namespace "${ns}" &>/dev/null || kubectl create namespace "${ns}" >/dev/null
    if kubectl apply -f "${f}" >/dev/null 2>&1; then
      echo "   ♻️  ${ns}/${name}"
      restored=$((restored + 1))
    else
      echo "   ⚠️  failed to restore ${ns}/${name}"
    fi
  done
  echo "✅ cert-persist: restored ${restored} secret(s). cert-manager will adopt valid certs and skip re-issuance."
}

case "${MODE}" in
  save)    save ;;
  restore) restore ;;
  *) echo "usage: $0 {save|restore}" >&2; exit 2 ;;
esac
