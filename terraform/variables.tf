variable "aws_region" {
  description = "Región de AWS donde se despliega el laboratorio"
  type        = string
  default     = "us-east-2"
}

variable "entorno" {
  description = "Nombre del entorno"
  type        = string
  default     = "dev"
}

variable "prefijo" {
  description = "Prefijo común para todos los recursos del laboratorio"
  type        = string
  default     = "lab09"
}

locals {
  nombre = "${var.prefijo}-${var.entorno}"
}
