output "alb_controller_role_arn" {
  value = module.irsa_alb.role_arn
}

output "cluster_autoscaler_role_arn" {
  value = module.irsa_cluster_autoscaler.role_arn
}

# Downstream modules should depend on this to ensure webhooks/CRDs exist.
output "ready" {
  value = {
    alb            = helm_release.alb_controller.status
    metrics_server = helm_release.metrics_server.status
    cert_manager   = helm_release.cert_manager.status
  }
}
