variable "aws_region" {
  description = "Región principal de AWS (São Paulo)"
  type        = string
  default     = "sa-east-1"
}

variable "aws_region_secundaria" {
  description = "Región secundaria de AWS para replicación multirregión y contingencia"
  type        = string
  default     = "us-east-1"
}

variable "habilitar_multiregion" {
  description = "Habilita DynamoDB Global Tables y la API de respaldo en la región secundaria"
  type        = bool
  default     = true
}

variable "entorno" {
  description = "Nombre del entorno"
  type        = string
  default     = "dev"
}

variable "prefijo" {
  description = "Prefijo común para todos los recursos del proyecto"
  type        = string
  default     = "lab09"
}

variable "correo_remitente" {
  description = "Correo verificado en Amazon SES para enviar los planes generados"
  type        = string
  default     = "notificaciones@nutriperu.pe"
}

variable "correo_alertas" {
  description = "Correo opcional para recibir notificaciones SNS de las alarmas de CloudWatch"
  type        = string
  default     = ""
}

variable "dominio" {
  description = "Dominio personalizado opcional en Route 53 (dejar vacío si no se tiene uno comprado)"
  type        = string
  default     = ""
}

variable "crear_zona_route53" {
  description = "Indica si Terraform debe crear la Hosted Zone en Route 53 cuando se define var.dominio"
  type        = bool
  default     = false
}

locals {
  nombre = "${var.prefijo}-${var.entorno}"
}
