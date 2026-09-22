output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.region
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_repositories" {
  value = module.ecr.repository_urls
}

output "grafana_admin_secret_arn" {
  value = module.monitoring.grafana_admin_secret_arn
}

output "grafana_port_forward" {
  value = "kubectl -n ${module.monitoring.namespace} port-forward svc/kps-grafana 3000:80"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
