variable "project" {
  type    = string
  default = "msplatform"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Restrict to office/VPN + CI egress."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "admin_role_arns" {
  description = "IAM roles to grant cluster-admin (GitHub Actions role, SRE role, ...)"
  type        = list(string)
  default     = []
}

variable "services" {
  description = "Microservice names – one ECR repo each"
  type        = list(string)
  default     = ["gateway", "orders", "products"]
}

variable "grafana_host" {
  type    = string
  default = ""
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}

variable "slack_webhook_url" {
  type      = string
  default   = ""
  sensitive = true
}
