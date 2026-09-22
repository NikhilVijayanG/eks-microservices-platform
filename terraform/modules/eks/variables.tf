variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "endpoint_public_access" {
  description = "Expose the API server publicly (restrict with endpoint_public_access_cidrs)"
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "node_groups" {
  description = "Managed node groups keyed by name"
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND") # ON_DEMAND | SPOT
    ami_type       = optional(string, "AL2023_x86_64_STANDARD")
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size      = optional(number, 50)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
  }))
}

variable "admin_role_arns" {
  description = "IAM principals granted cluster-admin via EKS access entries (e.g. the GitHub Actions role)"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
