locals {
  server_dir = "${path.module}/../server"
  server_files = [
    for f in fileset(local.server_dir, "**") : f
    if !can(regex("(^|/)(tests|__pycache__)/|\\.pyc$", f))
  ]
}

resource "aws_s3_object" "config" {
  for_each = toset(local.server_files)
  bucket   = aws_s3_bucket.backups.id
  key      = "config/${each.value}"
  source   = "${local.server_dir}/${each.value}"
  etag     = filemd5("${local.server_dir}/${each.value}")
}
