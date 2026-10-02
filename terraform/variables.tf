variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile. CI sets this to \"\" and uses OIDC credentials."
  type        = string
  default     = "dosaki"
}

variable "parent_domain" {
  type    = string
  default = "dosaki.net"
}

variable "server_label" {
  type    = string
  default = "minecraft"
}

variable "instance_type" {
  type    = string
  default = "m7g.xlarge"
}

variable "root_volume_gb" {
  type    = number
  default = 30
}

variable "backup_bucket" {
  type    = string
  default = "dosaki-minecraft-backups"
}

variable "map_bucket" {
  type    = string
  default = "dosaki-minecraft-map"
}

variable "budget_limit_usd" {
  type    = number
  default = 20
}

variable "budget_email" {
  type      = string
  sensitive = true
}
