output "namespace" {
  value = kubernetes_namespace_v1.monitoring.metadata[0].name
}

output "grafana_admin_secret_arn" {
  description = "Secrets Manager secret holding the Grafana admin credentials"
  value       = aws_secretsmanager_secret.grafana.arn
}

output "prometheus_url" {
  description = "In-cluster Prometheus endpoint"
  value       = "http://kps-prometheus.${var.namespace}.svc:9090"
}

output "grafana_url" {
  description = "In-cluster Grafana endpoint (port-forward or use the Ingress hostname)"
  value       = "http://kps-grafana.${var.namespace}.svc"
}

output "alertmanager_url" {
  value = "http://kps-alertmanager.${var.namespace}.svc:9093"
}
