terraform {
  required_version = ">= 1.9.0"

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

# Región principal: São Paulo (sa-east-1)
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

# Región secundaria para multirregión (Global Tables y API de respaldo)
provider "aws" {
  alias  = "secundaria"
  region = var.aws_region_secundaria

  default_tags {
    tags = {
      Proyecto   = "sistema-recomendacion-alimenticia"
      Entorno    = var.entorno
      Rol        = "multiregion-dr"
      Gestionado = "terraform"
    }
  }
}

# Proveedor en us-east-1 requerido por AWS para WAFv2 global de CloudFront
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Proyecto   = "sistema-recomendacion-alimenticia"
      Entorno    = var.entorno
      Gestionado = "terraform"
    }
  }
}
