output "web_cloudfront_url" {
  description = "URL pública de la aplicación web en CloudFront (con S3 + WAF)"
  value       = "https://${aws_cloudfront_distribution.web.domain_name}"
}

output "s3_web_bucket" {
  description = "Nombre del bucket S3 donde se aloja la web estática"
  value       = aws_s3_bucket.web.bucket
}

output "api_url" {
  description = "URL base de la API en la región principal (São Paulo - sa-east-1)"
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "api_secundaria_url" {
  description = "URL base de la API de contingencia en la región secundaria (us-east-1)"
  value       = var.habilitar_multiregion ? aws_apigatewayv2_api.http_secundaria[0].api_endpoint : null
}

output "prueba_salud" {
  description = "Abrir en el navegador para comprobar que la API principal responde"
  value       = "${aws_apigatewayv2_api.http.api_endpoint}/salud"
}

output "prueba_salud_secundaria" {
  description = "Abrir en el navegador para comprobar que la API secundaria multirregión responde"
  value       = var.habilitar_multiregion ? "${aws_apigatewayv2_api.http_secundaria[0].api_endpoint}/salud" : null
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.usuarios.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cola_solicitudes" {
  value = aws_sqs_queue.solicitudes.url
}

output "cola_dlq" {
  value = aws_sqs_queue.solicitudes_dlq.url
}

output "tabla_planes" {
  description = "Tabla Global DynamoDB de planes"
  value       = aws_dynamodb_table.planes.name
}

output "tabla_perfiles" {
  description = "Tabla Global DynamoDB de perfiles"
  value       = aws_dynamodb_table.perfiles.name
}

output "eventbridge_bus" {
  description = "Bus de eventos de EventBridge"
  value       = aws_cloudwatch_event_bus.eventos.name
}

output "eventbridge_pipe" {
  description = "EventBridge Pipe conectado al stream de DynamoDB"
  value       = aws_pipes_pipe.plan_generado.name
}

output "sns_alarmas_arn" {
  description = "ARN del tópico SNS donde publican las alarmas de CloudWatch"
  value       = aws_sns_topic.alarmas.arn
}

output "waf_web_acl_arn" {
  description = "ARN del WebACL de AWS WAFv2 asociado a CloudFront"
  value       = aws_wafv2_web_acl.web.arn
}

output "route53_health_check_primario_id" {
  description = "ID del Health Check de Route 53 para la región principal"
  value       = aws_route53_health_check.api_primaria.id
}

output "beanstalk_application" {
  description = "Nombre de la aplicación en AWS Elastic Beanstalk"
  value       = aws_elastic_beanstalk_application.nutriperu.name
}

output "beanstalk_endpoint_url" {
  description = "URL del entorno desplegado en AWS Elastic Beanstalk"
  value       = var.habilitar_beanstalk ? "http://${aws_elastic_beanstalk_environment.env[0].endpoint_url}" : null
}
