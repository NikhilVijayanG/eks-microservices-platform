# Reusable IAM Role for Service Accounts (IRSA).

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

variable "name" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string }
variable "namespace" { type = string }
variable "service_account" { type = string }
variable "policy_arns" {
  type    = list(string)
  default = []
}
variable "inline_policy_json" {
  type    = string
  default = null
}
variable "attach_inline_policy" {
  description = "Set true when inline_policy_json is provided (must be statically known for count)"
  type        = bool
  default     = false
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  issuer = replace(var.oidc_provider_url, "https://", "")
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  count  = var.attach_inline_policy ? 1 : 0
  name   = "${var.name}-inline"
  role   = aws_iam_role.this.id
  policy = var.inline_policy_json
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}
