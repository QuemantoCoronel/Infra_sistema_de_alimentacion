terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # El bucket, la clave y la región se pasan en "terraform init"
  # (desde GitHub Actions o desde backend.hcl en local).
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Proyecto   = "sistema-recomendacion-alimenticia"
      Entorno    = var.entorno
      Gestionado = "terraform"
    }
  }
}
