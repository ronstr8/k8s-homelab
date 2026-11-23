# Shared by the shell-into-a-data-store scripts (psql.sh, redis-cli.sh).
# Source it; don't run it.

# find_one_pod WHAT SELECTOR [NAMESPACE]
# Sets POD_NS and POD_NAME to the single running pod matching SELECTOR (in
# NAMESPACE, or across all namespaces when it's empty). Exits with a message
# naming WHAT if there are none or several: the homelab doesn't run these
# servers itself, a dependent project's chart does, so we find them by label.
find_one_pod() {
    local what="$1" selector="$2" namespace="${3:-}" scope=(--all-namespaces) pods
    [[ -n "$namespace" ]] && scope=(-n "$namespace")
    mapfile -t pods < <(kubectl get pods "${scope[@]}" -l "$selector" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')

    if (( ${#pods[@]} == 0 )); then
        echo "❌ No running $what pod matches '$selector'${namespace:+ in namespace $namespace}." >&2
        exit 1
    fi
    if (( ${#pods[@]} > 1 )); then
        echo "❌ More than one $what pod matches; pick one by namespace:" >&2
        printf '   %s\n' "${pods[@]}" >&2
        exit 1
    fi
    read -r POD_NS POD_NAME <<<"${pods[0]}"
}

# kubectl exec flags: -t only with a terminal, so piping output still works.
exec_tty_flags() {
    if [[ -t 0 && -t 1 ]]; then echo "-it"; else echo "-i"; fi
}
