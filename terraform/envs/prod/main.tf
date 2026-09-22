terraform {
  required_version = ">= 1.6"

  backend "s3" {
    key     = "eks-platform/prod/terraform.tfstate"
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
  env          = "prod"
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
  cidr               = "10.20.0.0/16"
  az_count           = 3
  single_nat_gateway = false # one NAT per AZ for HA
  tags               = local.tags
}

module "eks" {
  source                       = "../../modules/eks"
  cluster_name                 = local.cluster_name
  cluster_version              = var.cluster_version
  vpc_id                       = module.vpc.vpc_id
  private_subnet_ids           = module.vpc.private_subnet_ids
  endpoint_public_access       = true # set false + use VPN/bastion for fully private
  endpoint_public_access_cidrs = var.api_allowed_cidrs
  admin_role_arns              = var.admin_role_arns
  log_retention_days           = 90

  node_groups = {
    # Stable on-demand pool for platform components (monitoring, controllers)
    system = {
      instance_types = ["m6i.large", "m5.large"]
      capacity_type  = "ON_DEMAND"
      desired_size   = 3
      min_size       = 3
      max_size       = 6
      disk_size      = 80
      labels         = { workload = "system" }
      taints         = [{ key = "workload", value = "system", effect = "NO_SCHEDULE" }]
    }
    # Application pool – spot-diversified for cost, autoscaled
    apps = {
      instance_types = ["m6i.xlarge", "m5.xlarge", "m5a.xlarge", "m6a.xlarge"]
      capacity_type  = "SPOT"
      desired_size   = 3
      min_size       = 3
      max_size       = 20
      disk_size      = 100
      labels         = { workload = "apps" }
    }
  }
  tags = local.tags
}

module "ecr" {
  source             = "../../modules/ecr"
  repositories       = [for s in var.services : "${var.project}/${s}"]
  keep_tagged_images = 50
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
  prometheus_replicas        = 2
  alertmanager_replicas      = 3
  metrics_retention_days     = 30
  prometheus_storage_size_gb = 200
  enable_loki                = true
  log_retention_days         = 14
  loki_storage_size          = "200Gi"
  enable_ingress             = true
  ingress_scheme             = "internal" # reach Grafana via VPN; flip to internet-facing + SSO if needed
  grafana_host               = var.grafana_host
  acm_certificate_arn        = var.acm_certificate_arn
  slack_webhook_url          = var.slack_webhook_url
  tags                       = local.tags
  depends_on                 = [module.addons]
}

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
