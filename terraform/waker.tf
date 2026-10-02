resource "aws_ssm_parameter" "maintenance" {
  name  = "/minecraft/maintenance"
  type  = "String"
  value = "false"
  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_cloudwatch_log_group" "dns_queries" {
  provider          = aws.us_east_1
  name              = "/aws/route53/${local.fqdn}"
  retention_in_days = 3
}

data "aws_iam_policy_document" "route53_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:us-east-1:${local.account}:log-group:/aws/route53/*"]
    principals {
      type        = "Service"
      identifiers = ["route53.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "route53" {
  provider        = aws.us_east_1
  policy_name     = "minecraft-server-route53-query-logging"
  policy_document = data.aws_iam_policy_document.route53_logs.json
}

resource "aws_route53_query_log" "mc" {
  depends_on               = [aws_cloudwatch_log_resource_policy.route53]
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.dns_queries.arn
  zone_id                  = aws_route53_zone.mc.zone_id
}

data "archive_file" "waker" {
  type        = "zip"
  source_file = "${path.module}/../lambda/waker/handler.py"
  output_path = "${path.module}/.build/waker.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "waker" {
  name                 = "minecraft-server-waker"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.workload_boundary_arn

  # Permissions boundary is required by the deploy role's IAM policy (see bootstrap/main.tf)
}

data "aws_iam_policy_document" "waker" {
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
  statement {
    actions   = ["ec2:StartInstances"]
    resources = [aws_instance.mc.arn]
  }
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.maintenance.arn]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.waker.arn}:*"]
  }
}

resource "aws_iam_role_policy" "waker" {
  name   = "waker"
  role   = aws_iam_role.waker.id
  policy = data.aws_iam_policy_document.waker.json
}

resource "aws_cloudwatch_log_group" "waker" {
  provider          = aws.us_east_1
  name              = "/aws/lambda/minecraft-server-waker"
  retention_in_days = 14
}

resource "aws_lambda_function" "waker" {
  provider         = aws.us_east_1
  function_name    = "minecraft-server-waker"
  role             = aws_iam_role.waker.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.waker.output_path
  source_code_hash = data.archive_file.waker.output_base64sha256
  timeout          = 30
  depends_on       = [aws_cloudwatch_log_group.waker]

  environment {
    variables = {
      INSTANCE_ID       = aws_instance.mc.id
      INSTANCE_REGION   = var.region
      MAINTENANCE_PARAM = aws_ssm_parameter.maintenance.name
      WAKE_NAMES        = join(",", [local.fqdn, "_minecraft._tcp.${local.fqdn}"])
    }
  }
}

resource "aws_lambda_permission" "logs" {
  provider      = aws.us_east_1
  statement_id  = "AllowRoute53QueryLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.waker.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.dns_queries.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "waker" {
  provider        = aws.us_east_1
  name            = "minecraft-server-waker"
  log_group_name  = aws_cloudwatch_log_group.dns_queries.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.waker.arn
  depends_on      = [aws_lambda_permission.logs]
}

import {
  to = aws_ssm_parameter.maintenance
  id = "/minecraft/maintenance"
}
