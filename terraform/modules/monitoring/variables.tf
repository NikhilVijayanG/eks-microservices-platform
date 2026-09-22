variable "cluster_name" { type = string }

variable "namespace" {
  type    = string
  default = "monitoring"
}

variable "kube_prometheus_stack_chart_version" {
  type    = string
  default = "62.7.0"
}
variable "loki_chart_version" {
  type    = string
  default = "6.16.0"
}
variable "promtail_chart_version" {
  type    = string
  default = "6.16.5"
}

variable "prometheus_replicas" {
  type    = number
  default = 1
}
variable "alertmanager_replicas" {
  type    = number
  default = 1
}
variable "metrics_retention_days" {
  type    = number
  default = 15
}
variable "prometheus_storage_size_gb" {
  type    = number
  default = 50
}

variable "enable_loki" {
  type    = bool
  default = true
}
variable "log_retention_days" {
  type    = number
  default = 7
}
variable "loki_storage_size" {
  type    = string
  default = "50Gi"
}

variable "enable_ingress" {
  description = "Expose Grafana through an ALB Ingress"
  type        = bool
  default     = true
}
variable "ingress_scheme" {
  description = "internet-facing or internal"
  type        = string
  default     = "internal"
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
variable "slack_channel" {
  type    = string
  default = "#alerts"
}

variable "tags" {
  type    = map(string)
  default = {}
}
