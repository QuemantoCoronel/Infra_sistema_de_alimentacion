# API HTTP que recibe las solicitudes de la aplicación web
resource "aws_apigatewayv2_api" "http" {
  name          = "${local.nombre}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.http.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.usuarios.id}"
  }
}

locals {
  rutas = {
    salud        = { ruta = "GET /salud", protegida = false }
    crear-plan   = { ruta = "POST /planes", protegida = true }
    obtener-plan = { ruta = "GET /planes/{id}", protegida = true }
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  for_each               = local.rutas
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.funcion[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "ruta" {
  for_each           = local.rutas
  api_id             = aws_apigatewayv2_api.http.id
  route_key          = each.value.ruta
  target             = "integrations/${aws_apigatewayv2_integration.lambda[each.key].id}"
  authorization_type = each.value.protegida ? "JWT" : "NONE"
  authorizer_id      = each.value.protegida ? aws_apigatewayv2_authorizer.cognito.id : null
}

resource "aws_lambda_permission" "api" {
  for_each      = local.rutas
  statement_id  = "PermitirApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.funcion[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}
