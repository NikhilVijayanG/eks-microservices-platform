variable "project" {
  description = "Project name used as a prefix for all resources"
  type        = string
  default     = "msplatform"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the CI role, as owner/name"
  type        = string
}
