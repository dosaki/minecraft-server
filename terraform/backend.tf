# Locally: terraform init -backend-config="profile=dosaki"
terraform {
  backend "s3" {
    bucket       = "dosaki-minecraft-tfstate"
    key          = "main/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
}
