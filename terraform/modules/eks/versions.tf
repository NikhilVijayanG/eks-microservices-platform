terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws" }
    tls        = { source = "hashicorp/tls" }
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}
