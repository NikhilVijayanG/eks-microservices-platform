variable "cluster_name" { type = string }
variable "vpc_id" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string }

variable "alb_controller_version" {
  description = "Controller app version (for the IAM policy document)"
  type        = string
  default     = "2.8.2"
}
variable "alb_controller_chart_version" {
  type    = string
  default = "1.8.2"
}
variable "metrics_server_chart_version" {
  type    = string
  default = "3.12.1"
}
variable "cluster_autoscaler_chart_version" {
  type    = string
  default = "9.37.0"
}
variable "cert_manager_chart_version" {
  type    = string
  default = "v1.15.3"
}
variable "external_dns_chart_version" {
  type    = string
  default = "1.14.5"
}

variable "enable_external_dns" {
  type    = bool
  default = false
}
variable "route53_zone_id" {
  type    = string
  default = ""
}
variable "domain" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
