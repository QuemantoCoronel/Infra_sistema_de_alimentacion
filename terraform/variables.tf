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
  description = "Habilita DynamoDB Global Tables y la API de respaldo en la región secundaria (apagado por defecto en dev)"
  type        = bool
  default     = false
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

variable "sqs_visibility_timeout" {
  description = "Tiempo de visibilidad en segundos de la cola SQS de solicitudes (5 minutos según el informe)"
  type        = number
  default     = 300
}

variable "sqs_max_receive_count" {
  description = "Número máximo de intentos en SQS antes de enviar a la cola de errores DLQ"
  type        = number
  default     = 5
}

variable "waf_rate_limit" {
  description = "Límite de peticiones por IP cada 5 minutos en AWS WAFv2 (10 000 según el informe)"
  type        = number
  default     = 10000
}

variable "correo_remitente" {
  description = "Correo real para verificar en Amazon SES y enviar los planes generados"
  type        = string
  default     = "quemantocoronelgamer@gmail.com"
}

variable "correo_alertas" {
  description = "Correo opcional para recibir notificaciones SNS de las alarmas de CloudWatch"
  type        = string
  default     = ""
}

variable "dominio" {
  description = "Dominio propio opcional en Route 53 (dejar vacío si no se tiene uno registrado)"
  type        = string
  default     = ""
}

variable "crear_zona_route53" {
  description = "Indica si Terraform debe crear la Hosted Zone en Route 53 cuando se define var.dominio"
  type        = bool
  default     = false
}

variable "habilitar_beanstalk" {
  description = "Habilita el despliegue del Worker (PuLP + K-Means) en AWS Elastic Beanstalk"
  type        = bool
  default     = true
}

variable "beanstalk_instance_type" {
  description = "Tipo de instancia EC2 para el Worker en AWS Elastic Beanstalk"
  type        = string
  default     = "t3.micro"
}

locals {
  nombre = "${var.prefijo}-${var.entorno}"
}
