data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "mc" {
  name        = "minecraft-server"
  description = "Minecraft Java port only"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "minecraft" {
  security_group_id = aws_security_group.mc.id
  ip_protocol       = "tcp"
  from_port         = 25565
  to_port           = 25565
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.mc.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "random_password" "rcon" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "rcon" {
  name  = "/minecraft/rcon-password"
  type  = "SecureString"
  value = random_password.rcon.result
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name                 = "minecraft-server-instance"
  assume_role_policy   = data.aws_iam_policy_document.ec2_trust.json
  permissions_boundary = local.workload_boundary_arn # required by the deploy role's IAM policy (see bootstrap/main.tf)
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn, aws_s3_bucket.map.arn]
  }
  statement {
    sid       = "ReadConfig"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.backups.arn}/config/*"]
  }
  statement {
    sid       = "WriteBackups"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [for p in ["son", "father", "grandfather", "latest"] : "${aws_s3_bucket.backups.arn}/${p}/*"]
  }
  statement {
    sid       = "SyncMap"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.map.arn}/*"]
  }
  statement {
    sid       = "UpdateOwnDns"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.mc.arn]
  }
  statement {
    sid     = "ReadSecrets"
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.rcon.arn,
      "arn:aws:ssm:${var.region}:${local.account}:parameter/minecraft/players",
    ]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "minecraft-server-instance"
  role = aws_iam_role.instance.name
}

resource "aws_instance" "mc" {
  ami                                  = data.aws_ssm_parameter.al2023_arm64.value
  instance_type                        = var.instance_type
  subnet_id                            = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids               = [aws_security_group.mc.id]
  iam_instance_profile                 = aws_iam_instance_profile.instance.name
  associate_public_ip_address          = true
  instance_initiated_shutdown_behavior = "stop"

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false # keep the world if the instance is ever replaced
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region        = var.region
    backup_bucket = aws_s3_bucket.backups.bucket
    map_bucket    = aws_s3_bucket.map.bucket
    zone_id       = aws_route53_zone.mc.zone_id
    record_name   = local.fqdn
    rcon_param    = aws_ssm_parameter.rcon.name
  })

  # Config must be in S3 before first boot.
  depends_on = [aws_s3_object.config]

  tags = { Name = "minecraft-server" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
