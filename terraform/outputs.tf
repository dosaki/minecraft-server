output "instance_id" {
  value = aws_instance.mc.id
}

output "server_address" {
  value = local.fqdn
}

output "map_url" {
  value = "https://${local.map_fqdn}"
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}
