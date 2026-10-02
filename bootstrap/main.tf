terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # The state bucket is created by this stack; the first apply used local state, then
  # `terraform init -migrate-state -backend-config="profile=dosaki"` moved it here.
  backend "s3" {
    bucket       = "dosaki-minecraft-tfstate"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
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
  buckets = ["dosaki-minecraft-backups", "dosaki-minecraft-map"]
}

resource "aws_s3_bucket" "state" {
  bucket = "dosaki-minecraft-tfstate"

  lifecycle {
    prevent_destroy = true
  }
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

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid     = "Buckets"
    actions = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = flatten([for b in ["dosaki-minecraft-backups", "dosaki-minecraft-map"] :
    ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]])
  }
  statement {
    sid       = "OwnDns"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/*"]
    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["minecraft.dosaki.net", "*.minecraft.dosaki.net"]
    }
    condition {
      test     = "Null"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["false"]
    }
  }
  statement {
    sid = "SsmAgent"
    actions = [
      "ssm:UpdateInstanceInformation", "ssm:ListAssociations", "ssm:ListInstanceAssociations",
      "ssm:DescribeAssociation", "ssm:GetDocument", "ssm:DescribeDocument",
      "ssm:UpdateAssociationStatus", "ssm:UpdateInstanceAssociationStatus", "ssm:PutInventory",
      "ssm:PutComplianceItems", "ssm:PutConfigurePackageResult",
      "ssm:GetDeployablePatchSnapshotForInstance", "ssm:GetManifest",
      "ssmmessages:*", "ec2messages:*",
    ]
    resources = ["*"]
  }
  statement {
    sid     = "OwnParams"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:eu-west-1:${local.account}:parameter/minecraft/*",
      "arn:aws:ssm:eu-west-1:*:parameter/aws/service/*",
    ]
  }
  statement {
    sid       = "SecureStringViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.eu-west-1.amazonaws.com"]
    }
  }
  statement {
    sid       = "Waker"
    actions   = ["ec2:DescribeInstances", "ec2:StartInstances", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name   = "gha-minecraft-workload-boundary"
  policy = data.aws_iam_policy_document.workload_boundary.json
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
      "ssm:GetCommandInvocation", "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation", "ssm:DescribeParameters",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "SsmSendCommand"
    actions   = ["ssm:SendCommand"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["eu-west-1"]
    }
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
      "arn:aws:ssm:eu-west-1:*:parameter/aws/service/*",
    ]
  }
  statement {
    sid       = "Buckets"
    actions   = ["s3:*"]
    resources = flatten([for b in local.buckets : ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]])
  }
  statement {
    sid     = "StateBucket"
    actions = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::dosaki-minecraft-tfstate",
      "arn:aws:s3:::dosaki-minecraft-tfstate/main/*",
    ]
  }
  statement {
    sid     = "StackIamRead"
    actions = ["iam:Get*", "iam:List*"]
    resources = [
      "arn:aws:iam::${local.account}:role/minecraft-server-*",
      "arn:aws:iam::${local.account}:instance-profile/minecraft-server-*",
      "arn:aws:iam::${local.account}:policy/*",
    ]
  }
  statement {
    sid = "RolesMustCarryBoundary"
    actions = [
      "iam:CreateRole", "iam:PutRolePermissionsBoundary", "iam:PutRolePolicy",
      "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account}:role/minecraft-server-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }
  statement {
    sid = "RolesOther"
    actions = [
      "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.account}:role/minecraft-server-*"]
  }
  statement {
    sid = "InstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
    ]
    resources = ["arn:aws:iam::${local.account}:instance-profile/minecraft-server-*"]
  }
  statement {
    sid       = "OnlyKnownManagedPolicies"
    effect    = "Deny"
    actions   = ["iam:AttachRolePolicy"]
    resources = ["*"]
    condition {
      test     = "ArnNotLike"
      variable = "iam:PolicyARN"
      values = [
        "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
        "arn:aws:iam::${local.account}:policy/minecraft-server-*",
      ]
    }
  }
  statement {
    sid       = "KeepBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:DeletePolicy"]
    resources = [aws_iam_policy.workload_boundary.arn]
  }
  statement {
    sid       = "KeepBoundaryOnRoles"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["arn:aws:iam::${local.account}:role/*"]
  }
  statement {
    sid       = "OnlyMinecraftRecords"
    effect    = "Deny"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringNotLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["minecraft.dosaki.net", "*.minecraft.dosaki.net"]
    }
  }
  statement {
    sid    = "OnlyMinecraftDnsChanges"
    effect = "Deny"
    actions = [
      "route53:CreateTrafficPolicyInstance", "route53:UpdateTrafficPolicyInstance",
      "route53:DeleteTrafficPolicyInstance", "route53:DisableHostedZoneDNSSEC",
      "route53:DeactivateKeySigningKey", "route53:DeleteKeySigningKey",
    ]
    resources = ["*"]
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
output "workload_boundary_arn" { value = aws_iam_policy.workload_boundary.arn }
