output "api_url" {
  description = "URL base de la API"
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "prueba_salud" {
  description = "Abrir en el navegador para comprobar que la API responde"
  value       = "${aws_apigatewayv2_api.http.api_endpoint}/salud"
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

output "tabla_planes" {
  value = aws_dynamodb_table.planes.name
}
