resource "aws_s3_bucket" "map" {
  bucket = var.map_bucket
}

resource "aws_s3_bucket_public_access_block" "map" {
  bucket                  = aws_s3_bucket.map.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_acm_certificate" "map" {
  provider          = aws.us_east_1
  domain_name       = local.map_fqdn
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "map_validation" {
  for_each = {
    for o in aws_acm_certificate.map.domain_validation_options : o.domain_name => o
  }
  zone_id = data.aws_route53_zone.mc.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

resource "aws_acm_certificate_validation" "map" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.map.arn
  validation_record_fqdns = [for r in aws_route53_record.map_validation : r.fqdn]
}

resource "aws_cloudfront_origin_access_control" "map" {
  name                              = "minecraft-server-map"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_cache_policy" "map" {
  name        = "minecraft-server-map"
  min_ttl     = 0
  default_ttl = 300
  max_ttl     = 3600
  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

resource "aws_cloudfront_distribution" "map" {
  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [local.map_fqdn]
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "map-bucket"
    domain_name              = aws_s3_bucket.map.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.map.id
  }

  default_cache_behavior {
    target_origin_id       = "map-bucket"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.map.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.map.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

data "aws_iam_policy_document" "map_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.map.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.map.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "map" {
  bucket = aws_s3_bucket.map.id
  policy = data.aws_iam_policy_document.map_bucket.json
}

resource "aws_route53_record" "map" {
  for_each = toset(["A", "AAAA"])
  zone_id  = data.aws_route53_zone.mc.zone_id
  name     = local.map_fqdn
  type     = each.value
  alias {
    name                   = aws_cloudfront_distribution.map.domain_name
    zone_id                = aws_cloudfront_distribution.map.hosted_zone_id
    evaluate_target_health = false
  }
}
