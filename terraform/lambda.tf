# Una función Lambda atómica por ruta de API Gateway + la función de correos con SES
# (El motor pesado PuLP + K-Means se ejecuta en el Worker de AWS Elastic Beanstalk)
locals {
  funciones = {
    salud          = { handler = "salud.handler", timeout = 5, memoria = 128 }
    crear-plan     = { handler = "crear_plan.handler", timeout = 10, memoria = 256 }
    obtener-plan   = { handler = "obtener_plan.handler", timeout = 10, memoria = 256 }
    guardar-perfil = { handler = "guardar_perfil.handler", timeout = 10, memoria = 256 }
    obtener-perfil = { handler = "obtener_perfil.handler", timeout = 10, memoria = 256 }
    historial      = { handler = "historial.handler", timeout = 10, memoria = 256 }
    borrar-datos   = { handler = "borrar_datos.handler", timeout = 15, memoria = 256 }
    enviar-correo  = { handler = "enviar_correo.handler", timeout = 15, memoria = 256 }
  }
}

data "archive_file" "lambdas" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas"
  output_path = "${path.module}/build/lambdas.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = local.funciones
  name              = "/aws/lambda/${local.nombre}-${each.key}"
  retention_in_days = 365
}

resource "aws_lambda_function" "funcion" {
  for_each = local.funciones

  function_name    = "${local.nombre}-${each.key}"
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = "python3.11"
  handler          = each.value.handler
  timeout          = each.value.timeout
  memory_size      = each.value.memoria
  filename         = data.archive_file.lambdas.output_path
  source_code_hash = data.archive_file.lambdas.output_base64sha256

  tracing_config {
    mode = "Active"
  }
  environment {
    variables = {
      TABLA_PLANES     = aws_dynamodb_table.planes.name
      TABLA_PERFILES   = aws_dynamodb_table.perfiles.name
      COLA_URL         = aws_sqs_queue.solicitudes.url
      CORREOS_DLQ_URL  = aws_sqs_queue.correos_dlq.url
      CORREO_REMITENTE = var.correo_remitente
      SECRETO_ARN      = aws_secretsmanager_secret.app.arn
      CORS_ORIGIN      = local.cors_origen_principal
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
}
