data "aws_caller_identity" "current" {}

locals {
  account               = data.aws_caller_identity.current.account_id
  fqdn                  = "${var.server_label}.${var.parent_domain}"
  map_fqdn              = "map.${local.fqdn}"
  workload_boundary_arn = "arn:aws:iam::${local.account}:policy/gha-minecraft-workload-boundary"
}
