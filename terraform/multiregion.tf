# Despliegue multirregión en la región secundaria (us-east-1) consumiendo las réplicas de DynamoDB Global Tables
locals {
  funciones_secundarias = var.habilitar_multiregion ? {
    salud          = { handler = "salud.handler", timeout = 5, ruta = "GET /salud", protegida = false }
    obtener-plan   = { handler = "obtener_plan.handler", timeout = 10, ruta = "GET /planes/{id}", protegida = true }
    guardar-perfil = { handler = "guardar_perfil.handler", timeout = 10, ruta = "PUT /perfil", protegida = true }
    obtener-perfil = { handler = "obtener_perfil.handler", timeout = 10, ruta = "GET /perfil", protegida = true }
    historial      = { handler = "historial.handler", timeout = 10, ruta = "GET /historial", protegida = true }
    borrar-datos   = { handler = "borrar_datos.handler", timeout = 15, ruta = "DELETE /datos", protegida = true }
  } : {}
}

resource "aws_cloudwatch_log_group" "lambda_secundaria" {
  provider          = aws.secundaria
  for_each          = local.funciones_secundarias
  name              = "/aws/lambda/${local.nombre}-${each.key}"
  retention_in_days = 7
}

resource "aws_lambda_function" "funcion_secundaria" {
  provider = aws.secundaria
  for_each = local.funciones_secundarias

  function_name    = "${local.nombre}-${each.key}"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.11"
  handler          = each.value.handler
  timeout          = each.value.timeout
  memory_size      = 256
  filename         = data.archive_file.lambdas.output_path
  source_code_hash = data.archive_file.lambdas.output_base64sha256

  environment {
    variables = {
      TABLA_PLANES   = aws_dynamodb_table.planes.name
      TABLA_PERFILES = aws_dynamodb_table.perfiles.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_secundaria,
    aws_iam_role_policy.lambda_permisos,
    aws_dynamodb_table.planes,
    aws_dynamodb_table.perfiles,
  ]
}

resource "aws_apigatewayv2_api" "http_secundaria" {
  provider      = aws.secundaria
  count         = var.habilitar_multiregion ? 1 : 0
  name          = "${local.nombre}-api-dr"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_stage" "default_secundaria" {
  provider    = aws.secundaria
  count       = var.habilitar_multiregion ? 1 : 0
  api_id      = aws_apigatewayv2_api.http_secundaria[0].id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_authorizer" "cognito_secundaria" {
  provider         = aws.secundaria
  count            = var.habilitar_multiregion ? 1 : 0
  api_id           = aws_apigatewayv2_api.http_secundaria[0].id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.usuarios.id}"
  }
}

resource "aws_apigatewayv2_integration" "lambda_secundaria" {
  provider               = aws.secundaria
  for_each               = local.funciones_secundarias
  api_id                 = aws_apigatewayv2_api.http_secundaria[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.funcion_secundaria[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "ruta_secundaria" {
  provider           = aws.secundaria
  for_each           = local.funciones_secundarias
  api_id             = aws_apigatewayv2_api.http_secundaria[0].id
  route_key          = each.value.ruta
  target             = "integrations/${aws_apigatewayv2_integration.lambda_secundaria[each.key].id}"
  authorization_type = each.value.protegida ? "JWT" : "NONE"
  authorizer_id      = each.value.protegida ? aws_apigatewayv2_authorizer.cognito_secundaria[0].id : null
}

resource "aws_lambda_permission" "api_secundaria" {
  provider      = aws.secundaria
  for_each      = local.funciones_secundarias
  statement_id  = "PermitirApiGatewaySecundaria"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.funcion_secundaria[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_secundaria[0].execution_arn}/*/*"
}

