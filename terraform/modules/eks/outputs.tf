output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group (nodes and control plane)"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  value = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "node_group_names" {
  value = keys(aws_eks_node_group.this)
}
