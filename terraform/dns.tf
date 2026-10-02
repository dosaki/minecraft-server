# The zone and its delegation from the parent are owned by the bootstrap stack, so the
# deploy role's Route 53 write access can be pinned to this one zone.
data "aws_route53_zone" "mc" {
  name         = local.fqdn
  private_zone = false
}

# The instance UPSERTs its own IP on every boot; Terraform only creates the record.
resource "aws_route53_record" "server" {
  zone_id = data.aws_route53_zone.mc.zone_id
  name    = local.fqdn
  type    = "A"
  ttl     = 30
  records = ["192.0.2.1"]
  lifecycle {
    ignore_changes = [records]
  }
}
