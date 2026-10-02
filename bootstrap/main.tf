terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # After the first apply, uncomment and run `terraform init -migrate-state -backend-config="profile=dosaki"`.
  # backend "s3" {
  #   bucket       = "dosaki-minecraft-tfstate"
  #   key          = "bootstrap/terraform.tfstate"
  #   region       = "eu-west-1"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}

variable "aws_profile" {
  type    = string
  default = "dosaki"
}

variable "github_repo" {
  type    = string
  default = "dosaki/minecraft-server"
}

provider "aws" {
  region  = "eu-west-1"
  profile = var.aws_profile == "" ? null : var.aws_profile
  default_tags {
    tags = { Project = "minecraft-server" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  buckets = ["dosaki-minecraft-tfstate", "dosaki-minecraft-backups", "dosaki-minecraft-map"]
}

resource "aws_s3_bucket" "state" {
  bucket = "dosaki-minecraft-tfstate"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:pull_request",
        "repo:${var.github_repo}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "gha-minecraft-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_trust.json
}

resource "aws_iam_role" "plan" {
  name               = "gha-minecraft-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "Ec2InHomeRegion"
    actions   = ["ec2:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["eu-west-1"]
    }
  }
  statement {
    sid = "GlobalAndEdgeServices"
    actions = [
      "route53:*", "cloudfront:*", "acm:*", "budgets:*", "logs:*",
      "sts:GetCallerIdentity", "tag:GetResources",
      "ssm:SendCommand", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation", "ssm:DescribeParameters",
    ]
    resources = ["*"]
  }
  statement {
    sid     = "Lambda"
    actions = ["lambda:*"]
    resources = [
      "arn:aws:lambda:us-east-1:${local.account}:function:minecraft-server-*",
    ]
  }
  statement {
    sid     = "SsmParameters"
    actions = ["ssm:*"]
    resources = [
      "arn:aws:ssm:eu-west-1:${local.account}:parameter/minecraft/*",
      "arn:aws:ssm:eu-west-1::parameter/aws/service/*",
    ]
  }
  statement {
    sid       = "Buckets"
    actions   = ["s3:*"]
    resources = flatten([for b in local.buckets : ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]])
  }
  statement {
    sid     = "StackIam"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${local.account}:role/minecraft-server-*",
      "arn:aws:iam::${local.account}:instance-profile/minecraft-server-*",
      "arn:aws:iam::${local.account}:policy/minecraft-server-*",
    ]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "deploy_role_arn" { value = aws_iam_role.deploy.arn }
output "plan_role_arn" { value = aws_iam_role.plan.arn }
