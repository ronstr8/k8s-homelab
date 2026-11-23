#!/bin/bash
# Turn on ingress-nginx's Prometheus metrics and have Prometheus scrape them.
#
# The upstream Kind manifest ships the controller with --enable-metrics=false.
# Flipping it restarts the controller, which drops open connections, including
# telnet sessions on 8888. So it only touches the Deployment when the flag or
# port is actually missing; re-runs leave a working controller alone.
#
# Run by monitoring-setup.sh, after the chart has installed the ServiceMonitor CRD.
set -euo pipefail

NS=ingress-nginx
DEPLOY=ingress-nginx-controller
METRICS_PORT=10254

current=$(kubectl get deployment "${DEPLOY}" -n "${NS}" -o json)

has_flag=$(jq '[.spec.template.spec.containers[0].args[]] | index("--enable-metrics=true") != null' <<<"${current}")
has_port=$(jq --argjson p "${METRICS_PORT}" \
  '[.spec.template.spec.containers[0].ports[]?.containerPort] | index($p) != null' <<<"${current}")

if [[ "${has_flag}" == "true" && "${has_port}" == "true" ]]; then
  echo "   ✅ ingress-nginx metrics already enabled."
else
  echo "   ⚠️  Restarting ingress-nginx to enable metrics (open connections will drop)..."
  jq --argjson p "${METRICS_PORT}" '
    .spec.template.spec.containers[0] |= (
      .args = ([.args[] | select(startswith("--enable-metrics=") | not)] + ["--enable-metrics=true"])
      | .ports = ([.ports[]? | select(.containerPort != $p)]
                  + [{name: "metrics", containerPort: $p, protocol: "TCP"}])
    )' <<<"${current}" | kubectl replace -f - >/dev/null
  kubectl rollout status deployment/"${DEPLOY}" -n "${NS}" --timeout=180s
fi

kubectl apply -f "$(dirname "$0")/../resources/ingress-nginx-metrics.yaml"
