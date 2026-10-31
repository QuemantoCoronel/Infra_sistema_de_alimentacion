# Una función Lambda por ruta (funciones atómicas) y un worker para la cola
locals {
  funciones = {
    salud        = { handler = "salud.handler", timeout = 5 }
    crear-plan   = { handler = "crear_plan.handler", timeout = 10 }
    obtener-plan = { handler = "obtener_plan.handler", timeout = 10 }
    worker       = { handler = "worker.handler", timeout = 60 }
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
  retention_in_days = 7
}

resource "aws_lambda_function" "funcion" {
  for_each = local.funciones

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
      TABLA_PLANES = aws_dynamodb_table.planes.name
      COLA_URL     = aws_sqs_queue.solicitudes.url
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda_permisos]
}

# El worker se activa con cada mensaje que llega a la cola
resource "aws_lambda_event_source_mapping" "worker_sqs" {
  event_source_arn = aws_sqs_queue.solicitudes.arn
  function_name    = aws_lambda_function.funcion["worker"].arn
  batch_size       = 1
}
