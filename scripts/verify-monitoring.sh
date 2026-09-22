#!/usr/bin/env bash
# Verify the observability stack end-to-end from a workstation with kubectl access.
set -uo pipefail
NS=monitoring
q() { curl -sf --retry 5 --retry-delay 1 --retry-connrefused "$@"; }
pf() { kubectl -n "$NS" port-forward "svc/$1" "$2" >/dev/null 2>&1 & echo $!; }

P=$(pf kps-prometheus 19090:9090); L=$(pf loki 13100:3100); G=$(pf kps-grafana 13000:80); sleep 4
trap 'kill $P $L $G 2>/dev/null' EXIT

echo "== Prometheus targets (microservices namespace)"
q localhost:19090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.namespace=="microservices") | "  \(.labels.service // .labels.job)\t\(.labels.pod)\t\(.health)"'
echo "== All targets"
q localhost:19090/api/v1/targets | jq -r '.data.activeTargets | "  \(length) targets, \(map(select(.health=="up"))|length) up"'
echo "== Rules"
q localhost:19090/api/v1/rules | jq -r '[.data.groups[] | select(.name|startswith("microservices"))] | "  groups: \(map(.name))  rules: \(map(.rules|length)|add)"'
q localhost:19090/api/v1/alerts | jq -r '.data.alerts | map(select(.labels.alertname!="Watchdog")) | if length==0 then "  active alerts: none" else "  active: " + (map("\(.labels.alertname)(\(.state))")|join(", ")) end'
echo "== Live RED metrics"
q 'localhost:19090/api/v1/query?query=sum by (service) (rate(http_requests_total{namespace="microservices"}[5m]))' | jq -r '.data.result[] | "  req/s  \(.metric.service)\t\(.value[1]|tonumber|.*100|round/100)"'
q 'localhost:19090/api/v1/query?query=service:http_errors:ratio5m' | jq -r '.data.result[] | "  err%   \(.metric.service)\t\(.value[1]|tonumber|.*1000|round/10)"'
q 'localhost:19090/api/v1/query?query=service:http_latency_p95:5m' | jq -r '.data.result[] | "  p95ms  \(.metric.service)\t\(.value[1]|tonumber|.*10000|round/10)"'
q 'localhost:19090/api/v1/query?query=sum by (result) (orders_created_total)' | jq -r '.data.result[] | "  orders \(.metric.result)\t\(.value[1])"'
echo "== Loki log lines from microservices (last 15m)"
q -G localhost:13100/loki/api/v1/query --data-urlencode 'query=sum by (app) (count_over_time({namespace="microservices"}[15m]))' | jq -r '.data.result[] | "  \(.metric.app // "?")\t\(.value[1]) lines"'
echo "== Grafana"
PASS=$(aws secretsmanager get-secret-value --region "${AWS_REGION:-us-east-1}" --secret-id "${1:-msplatform-dev}/grafana-admin" --query SecretString --output text | jq -r .password)
q -u "admin:$PASS" localhost:13000/api/health | jq -r '"  health: \(.database) v\(.version)"'
q -u "admin:$PASS" 'localhost:13000/api/search?type=dash-db' | jq -r '"  dashboards: \(length) total; ours: " + (map(select(.title|test("Microservices")))|map(.title)|join(", "))'
q -u "admin:$PASS" localhost:13000/api/datasources | jq -r '"  datasources: " + (map(.name)|join(", "))'
