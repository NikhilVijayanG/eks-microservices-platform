#!/usr/bin/env bash
# Generate traffic (and optional errors) against the gateway to exercise dashboards, HPA and alerts.
# Usage: scripts/load-test.sh [gateway_url] [duration_s] [error_rate 0..1]
set -euo pipefail
GW="${1:-$(kubectl -n microservices get ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' | sed 's#^#http://#')}"
DURATION="${2:-120}"
ERR="${3:-0}"

echo "Target: $GW  duration: ${DURATION}s  error-rate: $ERR"
end=$((SECONDS + DURATION))
i=0
while (( SECONDS < end )); do
  curl -s -o /dev/null "$GW/api/products" &
  curl -s -o /dev/null "$GW/api/products/p-10$((i % 4))" &
  curl -s -o /dev/null -X POST "$GW/api/orders" -H 'content-type: application/json' -d "{\"productId\":\"p-10$((i % 4))\",\"quantity\":$((i % 3 + 1))}" &
  if [[ "$ERR" != "0" ]]; then curl -s -o /dev/null "$GW/api/products/fail?rate=$ERR" & fi
  (( i++ )) || true
  (( i % 50 == 0 )) && { wait; echo "  $i iterations…"; }
  sleep 0.05
done
wait
echo "done: $i iterations"
