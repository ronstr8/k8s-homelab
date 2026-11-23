#!/usr/bin/env bash
# Open redis-cli inside the cluster's Redis pod.
#
# Like psql.sh: a dependent project's chart runs Redis (today: logodal's
# Bitnami chart), so the pod is found by label, and redis-cli runs inside it.
# If the chart enables auth, the password is read from the container's own
# REDIS_PASSWORD there, so it never leaves the pod.
#
#   REDIS_NAMESPACE  namespace to look in (empty = search all namespaces)
#   REDIS_SELECTOR   label selector for the server pod
#   REDIS_CONTAINER  container in the pod that has redis-cli
#   Any arguments are passed straight to redis-cli.
set -euo pipefail

REDIS_NAMESPACE="${REDIS_NAMESPACE:-}"
REDIS_SELECTOR="${REDIS_SELECTOR:-app.kubernetes.io/name=redis,app.kubernetes.io/component=master}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis}"

# shellcheck source=lib/cluster-pod.sh
source "$(dirname "$0")/lib/cluster-pod.sh"
find_one_pod Redis "$REDIS_SELECTOR" "$REDIS_NAMESPACE"

echo "🟥 $POD_NS/$POD_NAME" >&2

# Expanded inside the pod. REDISCLI_AUTH keeps the password off the command line.
# shellcheck disable=SC2016
exec kubectl exec "$(exec_tty_flags)" -n "$POD_NS" "$POD_NAME" -c "$REDIS_CONTAINER" -- \
    sh -c '
        [ -n "${REDIS_PASSWORD:-}" ] && export REDISCLI_AUTH="$REDIS_PASSWORD"
        exec redis-cli "$@"
    ' redis-cli "$@"
