# EKS cluster with managed node groups, IRSA (OIDC), envelope encryption, control-plane logging
# and the core managed addons (vpc-cni, coredns, kube-proxy, ebs-csi, pod-identity-agent).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------- IAM: cluster
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSVPCResourceController",
  ])
  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# ---------------------------------------------------------------- KMS for secrets encryption
resource "aws_kms_key" "eks" {
  description             = "EKS secrets envelope encryption for ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# ---------------------------------------------------------------- cluster
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster"
  description = "EKS control plane additional SG"
  vpc_id      = var.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.tags, { Name = "${var.cluster_name}-cluster" })
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access_cidrs
    security_group_ids      = [aws_security_group.cluster.id]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    provider { key_arn = aws_kms_key.eks.arn }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]
}

# ---------------------------------------------------------------- OIDC / IRSA
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

# ---------------------------------------------------------------- IAM: nodes
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
    # vpc-cni runs with its own IRSA role below, but the node policy is still required for bootstrap
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ---------------------------------------------------------------- node groups
resource "aws_launch_template" "node" {
  for_each    = var.node_groups
  name_prefix = "${var.cluster_name}-${each.key}-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring { enabled = true }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-${each.key}" })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-${each.key}" })
  }

  tags = var.tags
}

resource "aws_eks_node_group" "this" {
  for_each        = var.node_groups
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = var.cluster_version

  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type
  ami_type       = each.value.ami_type

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  update_config { max_unavailable_percentage = 33 }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  labels = merge({ "node-group" = each.key }, each.value.labels)

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  # Cluster Autoscaler discovery
  tags = merge(var.tags, {
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size] # autoscaler owns this
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ---------------------------------------------------------------- IRSA roles for addons
module "irsa_vpc_cni" {
  source            = "./irsa"
  name              = "${var.cluster_name}-vpc-cni"
  oidc_provider_arn = aws_iam_openid_connect_provider.this.arn
  oidc_provider_url = aws_eks_cluster.this.identity[0].oidc[0].issuer
  namespace         = "kube-system"
  service_account   = "aws-node"
  policy_arns       = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"]
  tags              = var.tags
}

module "irsa_ebs_csi" {
  source            = "./irsa"
  name              = "${var.cluster_name}-ebs-csi"
  oidc_provider_arn = aws_iam_openid_connect_provider.this.arn
  oidc_provider_url = aws_eks_cluster.this.identity[0].oidc[0].issuer
  namespace         = "kube-system"
  service_account   = "ebs-csi-controller-sa"
  policy_arns       = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
  tags              = var.tags
}

# ---------------------------------------------------------------- managed addons
locals {
  addons = {
    vpc-cni = {
      role_arn = module.irsa_vpc_cni.role_arn
      config   = jsonencode({ env = { ENABLE_PREFIX_DELEGATION = "true", WARM_PREFIX_TARGET = "1" } })
    }
    coredns                = { role_arn = null, config = null }
    kube-proxy             = { role_arn = null, config = null }
    eks-pod-identity-agent = { role_arn = null, config = null }
    aws-ebs-csi-driver     = { role_arn = module.irsa_ebs_csi.role_arn, config = null }
  }
}

data "aws_eks_addon_version" "this" {
  for_each           = local.addons
  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "this" {
  for_each                    = local.addons
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  service_account_role_arn    = each.value.role_arn
  configuration_values        = each.value.config
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = var.tags

  # coredns needs nodes to schedule onto
  depends_on = [aws_eks_node_group.this]
}

# ---------------------------------------------------------------- access entries (cluster admins)
resource "aws_eks_access_entry" "admin" {
  for_each      = toset(var.admin_role_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = toset(var.admin_role_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.admin]
}

# ---------------------------------------------------------------- gp3 default StorageClass
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters             = { type = "gp3", encrypted = "true" }
  depends_on             = [aws_eks_addon.this]
}

resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata { name = "gp2" }
  annotations = { "storageclass.kubernetes.io/is-default-class" = "false" }
  force       = true
  depends_on  = [aws_eks_addon.this]
}
