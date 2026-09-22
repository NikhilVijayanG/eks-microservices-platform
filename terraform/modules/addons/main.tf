# Platform addons installed with Helm: AWS Load Balancer Controller, metrics-server,
# Cluster Autoscaler, cert-manager and (optionally) external-dns.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = ">= 5.60" }
    helm       = { source = "hashicorp/helm", version = ">= 2.12" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.25" }
    http       = { source = "hashicorp/http", version = ">= 3.4" }
  }
}

data "aws_region" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------- AWS Load Balancer Controller
data "http" "alb_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v${var.alb_controller_version}/docs/install/iam_policy.json"
}

module "irsa_alb" {
  source               = "../eks/irsa"
  name                 = "${var.cluster_name}-alb-controller"
  oidc_provider_arn    = var.oidc_provider_arn
  oidc_provider_url    = var.oidc_provider_url
  namespace            = "kube-system"
  service_account      = "aws-load-balancer-controller"
  inline_policy_json   = data.http.alb_policy.response_body
  attach_inline_policy = true
  tags                 = var.tags
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = data.aws_region.current.name
    vpcId       = var.vpc_id
    serviceAccount = {
      create      = true
      name        = "aws-load-balancer-controller"
      annotations = { "eks.amazonaws.com/role-arn" = module.irsa_alb.role_arn }
    }
    replicaCount                = 2
    enableServiceMutatorWebhook = false
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
    podDisruptionBudget = { maxUnavailable = 1 }
  })]
}

# ---------------------------------------------------------------- metrics-server (HPA)
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"
  wait       = true

  values = [yamlencode({
    replicas = 2
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
    podDisruptionBudget = { enabled = true, minAvailable = 1 }
  })]
}

# ---------------------------------------------------------------- Cluster Autoscaler
data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeImages",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }
  statement {
    actions   = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}

module "irsa_cluster_autoscaler" {
  source               = "../eks/irsa"
  name                 = "${var.cluster_name}-cluster-autoscaler"
  oidc_provider_arn    = var.oidc_provider_arn
  oidc_provider_url    = var.oidc_provider_url
  namespace            = "kube-system"
  service_account      = "cluster-autoscaler"
  inline_policy_json   = data.aws_iam_policy_document.cluster_autoscaler.json
  attach_inline_policy = true
  tags                 = var.tags
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"
  wait       = true

  values = [yamlencode({
    cloudProvider = "aws"
    awsRegion     = data.aws_region.current.name
    autoDiscovery = { clusterName = var.cluster_name }
    rbac = {
      serviceAccount = {
        create      = true
        name        = "cluster-autoscaler"
        annotations = { "eks.amazonaws.com/role-arn" = module.irsa_cluster_autoscaler.role_arn }
      }
    }
    extraArgs = {
      "balance-similar-node-groups"      = true
      "skip-nodes-with-system-pods"      = false
      "skip-nodes-with-local-storage"    = false
      "expander"                         = "least-waste"
      "scale-down-unneeded-time"         = "5m"
      "scale-down-utilization-threshold" = "0.5"
    }
    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { memory = "512Mi" }
    }
    podDisruptionBudget = { maxUnavailable = 1 }
  })]
}

# ---------------------------------------------------------------- cert-manager
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    crds = { enabled = true }
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
  })]
}

# ---------------------------------------------------------------- external-dns (optional)
data "aws_iam_policy_document" "external_dns" {
  count = var.enable_external_dns ? 1 : 0
  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.route53_zone_id}"]
  }
  statement {
    actions   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
    resources = ["*"]
  }
}

module "irsa_external_dns" {
  count                = var.enable_external_dns ? 1 : 0
  source               = "../eks/irsa"
  name                 = "${var.cluster_name}-external-dns"
  oidc_provider_arn    = var.oidc_provider_arn
  oidc_provider_url    = var.oidc_provider_url
  namespace            = "kube-system"
  service_account      = "external-dns"
  inline_policy_json   = data.aws_iam_policy_document.external_dns[0].json
  attach_inline_policy = true
  tags                 = var.tags
}

resource "helm_release" "external_dns" {
  count      = var.enable_external_dns ? 1 : 0
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_chart_version
  namespace  = "kube-system"
  wait       = true

  values = [yamlencode({
    provider      = { name = "aws" }
    domainFilters = [var.domain]
    policy        = "sync"
    txtOwnerId    = var.cluster_name
    serviceAccount = {
      create      = true
      name        = "external-dns"
      annotations = { "eks.amazonaws.com/role-arn" = module.irsa_external_dns[0].role_arn }
    }
  })]
}
