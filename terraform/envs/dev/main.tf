terraform {
  required_version = ">= 1.6"

  backend "s3" {
    # bucket / dynamodb_table / region are injected via -backend-config (see Makefile / CI)
    key     = "eks-platform/dev/terraform.tfstate"
    encrypt = true
  }

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.60" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.32" }
    helm       = { source = "hashicorp/helm", version = "~> 2.15" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
    http       = { source = "hashicorp/http", version = "~> 3.4" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = local.tags }
}

# Kubernetes/Helm providers authenticate with a short-lived token from the cluster we just created.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

locals {
  env          = "dev"
  cluster_name = "${var.project}-${local.env}"
  tags = {
    Project     = var.project
    Environment = local.env
    ManagedBy   = "terraform"
  }
}

module "vpc" {
  source             = "../../modules/vpc"
  name               = local.cluster_name
  region             = var.region
  cluster_name       = local.cluster_name
  cidr               = "10.10.0.0/16"
  az_count           = 2
  single_nat_gateway = true # cost-optimised for dev
  tags               = local.tags
}

module "eks" {
  source                       = "../../modules/eks"
  cluster_name                 = local.cluster_name
  cluster_version              = var.cluster_version
  vpc_id                       = module.vpc.vpc_id
  private_subnet_ids           = module.vpc.private_subnet_ids
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs
  admin_role_arns              = var.admin_role_arns
  log_retention_days           = 7

  node_groups = {
    general = {
      # Accounts on the AWS Free Tier *plan* can only launch free-tier-eligible types
      # (m7i-flex/c7i-flex/t3.small…); m7i-flex.large = 2 vCPU / 8 GiB. Switch to
      # ["t3.large","t3a.large"] with capacity_type = "SPOT" on a paid account.
      instance_types = ["m7i-flex.large", "c7i-flex.large"]
      capacity_type  = "ON_DEMAND"
      desired_size   = 2
      min_size       = 2
      max_size       = 4 # 8 vCPU default quota / 2 vCPU per node
      disk_size      = 50
      labels         = { workload = "general" }
    }
  }
  tags = local.tags
}

module "ecr" {
  source             = "../../modules/ecr"
  repositories       = [for s in var.services : "${var.project}/${s}"]
  keep_tagged_images = 20
  tags               = local.tags
}

module "addons" {
  source            = "../../modules/addons"
  cluster_name      = module.eks.cluster_name
  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.tags
  depends_on        = [module.eks]
}

module "monitoring" {
  source                     = "../../modules/monitoring"
  cluster_name               = module.eks.cluster_name
  prometheus_replicas        = 1
  alertmanager_replicas      = 1
  metrics_retention_days     = 7
  prometheus_storage_size_gb = 20
  enable_loki                = true
  log_retention_days         = 3
  loki_storage_size          = "20Gi"
  enable_ingress             = true
  ingress_scheme             = "internet-facing"
  grafana_host               = var.grafana_host
  acm_certificate_arn        = var.acm_certificate_arn
  slack_webhook_url          = var.slack_webhook_url
  tags                       = local.tags
  depends_on                 = [module.addons]
}

# Application namespaces with Pod Security + baseline NetworkPolicy defaults
resource "kubernetes_namespace_v1" "apps" {
  metadata {
    name = "microservices"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      environment                          = local.env
    }
  }
  depends_on = [module.eks]
}
