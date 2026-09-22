variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "cluster_name" {
  description = "EKS cluster name, used for subnet discovery tags"
  type        = string
}

variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 3
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6."
  }
}

variable "single_nat_gateway" {
  description = "One NAT gateway for all AZs (cheaper, dev) vs one per AZ (HA, prod)"
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
