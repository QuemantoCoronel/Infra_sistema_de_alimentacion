# Una función Lambda por ruta (funciones atómicas), el worker de IA y la función de correos SES
locals {
  funciones = {
    salud          = { handler = "salud.handler", timeout = 5, memoria = 256, usa_layer = false }
    crear-plan     = { handler = "crear_plan.handler", timeout = 10, memoria = 256, usa_layer = false }
    obtener-plan   = { handler = "obtener_plan.handler", timeout = 10, memoria = 256, usa_layer = false }
    guardar-perfil = { handler = "guardar_perfil.handler", timeout = 10, memoria = 256, usa_layer = false }
    obtener-perfil = { handler = "obtener_perfil.handler", timeout = 10, memoria = 256, usa_layer = false }
    historial      = { handler = "historial.handler", timeout = 10, memoria = 256, usa_layer = false }
    borrar-datos   = { handler = "borrar_datos.handler", timeout = 15, memoria = 256, usa_layer = false }
    worker         = { handler = "worker.handler", timeout = 60, memoria = 512, usa_layer = true }
    enviar-correo  = { handler = "enviar_correo.handler", timeout = 15, memoria = 256, usa_layer = false }
  }
}

data "archive_file" "lambdas" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas"
  output_path = "${path.module}/build/lambdas.zip"
}

data "archive_file" "layer_motor" {
  type        = "zip"
  source_dir  = "${path.module}/layer_motor"
  output_path = "${path.module}/build/layer_motor.zip"
}

resource "aws_lambda_layer_version" "motor_ia" {
  layer_name          = "${local.nombre}-motor-ia"
  description         = "Dependencias del motor de IA (PuLP MILP y scikit-learn K-Means)"
  filename            = data.archive_file.layer_motor.output_path
  source_code_hash    = data.archive_file.layer_motor.output_base64sha256
  compatible_runtimes = ["python3.11"]
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = local.funciones
  name              = "/aws/lambda/${local.nombre}-${each.key}"
  retention_in_days = 7
}

resource "aws_lambda_function" "funcion" {
  for_each = local.funciones

  function_name    = "${local.nombre}-${each.key}"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.11"
  handler          = each.value.handler
  timeout          = each.value.timeout
  memory_size      = each.value.memoria
  filename         = data.archive_file.lambdas.output_path
  source_code_hash = data.archive_file.lambdas.output_base64sha256
  layers           = each.value.usa_layer ? [aws_lambda_layer_version.motor_ia.arn] : []

  environment {
    variables = {
      TABLA_PLANES     = aws_dynamodb_table.planes.name
      TABLA_PERFILES   = aws_dynamodb_table.perfiles.name
      COLA_URL         = aws_sqs_queue.solicitudes.url
      CORREO_REMITENTE = var.correo_remitente
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda_permisos]
}

# El worker se activa con cada mensaje que llega a la cola SQS
resource "aws_lambda_event_source_mapping" "worker_sqs" {
  event_source_arn = aws_sqs_queue.solicitudes.arn
  function_name    = aws_lambda_function.funcion["worker"].arn
  batch_size       = 1
}
