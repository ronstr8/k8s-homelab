#!/usr/bin/env bash
# Open psql inside the cluster's PostgreSQL pod.
#
# The homelab doesn't run Postgres itself; a dependent project's Helm chart does
# (today: logodal's Bitnami chart). So we locate the pod by its standard label
# rather than hard-coding a namespace, and exec psql *inside* it using the
# credentials already in the container's env, so no secret ever leaves the pod.
#
#   PSQL_NAMESPACE  namespace to look in (empty = search all namespaces)
#   PSQL_SELECTOR   label selector for the server pod
#   PSQL_USER       role to connect as (empty = the chart's app user;
#                   "postgres" = superuser, using the chart's postgres password)
#   PSQL_DB         database (empty = the chart's app database)
#   PSQL_CONTAINER  container in the pod that has psql
#   Any arguments are passed straight to psql.
set -euo pipefail

PSQL_NAMESPACE="${PSQL_NAMESPACE:-}"
PSQL_SELECTOR="${PSQL_SELECTOR:-app.kubernetes.io/name=postgresql,app.kubernetes.io/component=primary}"
PSQL_USER="${PSQL_USER:-}"
PSQL_DB="${PSQL_DB:-}"
PSQL_CONTAINER="${PSQL_CONTAINER:-postgresql}"

# shellcheck source=lib/cluster-pod.sh
source "$(dirname "$0")/lib/cluster-pod.sh"
find_one_pod PostgreSQL "$PSQL_SELECTOR" "$PSQL_NAMESPACE"
ns="$POD_NS" pod="$POD_NAME"

echo "🐘 $ns/$pod" >&2

# Expanded inside the pod, where the chart's POSTGRES_* variables live.
# shellcheck disable=SC2016
exec kubectl exec "$(exec_tty_flags)" -n "$ns" "$pod" -c "$PSQL_CONTAINER" -- \
    env PSQL_USER="$PSQL_USER" PSQL_DB="$PSQL_DB" sh -c '
        user="${PSQL_USER:-${POSTGRES_USER:-postgres}}"
        if [ "$user" = postgres ]; then
            export PGPASSWORD="${POSTGRES_POSTGRES_PASSWORD:-$POSTGRES_PASSWORD}"
            db="${PSQL_DB:-postgres}"
        else
            export PGPASSWORD="$POSTGRES_PASSWORD"
            db="${PSQL_DB:-${POSTGRES_DATABASE:-$user}}"
        fi
        exec psql -h 127.0.0.1 -U "$user" -d "$db" "$@"
    ' psql "$@"
