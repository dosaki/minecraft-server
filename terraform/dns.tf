data "aws_route53_zone" "parent" {
  name         = var.parent_domain
  private_zone = false
}

resource "aws_route53_zone" "mc" {
  name = local.fqdn
}

resource "aws_route53_record" "delegation" {
  zone_id = data.aws_route53_zone.parent.zone_id
  name    = local.fqdn
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.mc.name_servers
}

# The instance UPSERTs its own IP on every boot; Terraform only creates the record.
resource "aws_route53_record" "server" {
  zone_id = aws_route53_zone.mc.zone_id
  name    = local.fqdn
  type    = "A"
  ttl     = 30
  records = ["192.0.2.1"]
  lifecycle {
    ignore_changes = [records]
  }
}
