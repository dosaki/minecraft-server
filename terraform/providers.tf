terraform {
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile == "" ? null : var.aws_profile
  default_tags {
    tags = { Project = "minecraft-server" }
  }
}

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile == "" ? null : var.aws_profile
  default_tags {
    tags = { Project = "minecraft-server" }
  }
}
