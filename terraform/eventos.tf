# Identidad de correo real en Amazon SES para el envío de planes nutricionales
resource "aws_ses_email_identity" "remitente" {
  count = var.correo_remitente != "" ? 1 : 0
  email = var.correo_remitente
}

# Bus de eventos dedicado en Amazon EventBridge
resource "aws_cloudwatch_event_bus" "eventos" {
  name = "${local.nombre}-eventos"
}

# EventBridge Pipe: escucha el stream de DynamoDB (tabla planes) y publica en EventBridge
# únicamente cuando el Worker en Elastic Beanstalk actualiza el estado del plan a "generado"
resource "aws_pipes_pipe" "plan_generado" {
  name     = "${local.nombre}-pipe-plan-generado"
  role_arn = aws_iam_role.pipes_exec.arn
  source   = aws_dynamodb_table.planes.stream_arn
  target   = aws_cloudwatch_event_bus.eventos.arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 1
    }

    filter_criteria {
      filter {
        pattern = jsonencode({
          eventName = ["MODIFY"]
          dynamodb = {
            OldImage = {
              estado = {
                S = ["pendiente"]
              }
            }
            NewImage = {
              estado = {
                S = ["generado"]
              }
            }
          }
        })
      }
    }
  }

  target_parameters {
    eventbridge_event_bus_parameters {
      detail_type = "PlanAlimenticioGenerado"
      source      = "nutriperu.planes"
    }
  }

  depends_on = [aws_iam_role_policy.pipes_permisos]
}

# Regla de EventBridge que enruta el evento de plan generado hacia la Lambda de correos SES
resource "aws_cloudwatch_event_rule" "enviar_correo" {
  name           = "${local.nombre}-regla-enviar-correo"
  description    = "Dispara la Lambda de correos SES cuando un plan nutricional pasa a estado generado"
  event_bus_name = aws_cloudwatch_event_bus.eventos.name

  event_pattern = jsonencode({
    source      = ["nutriperu.planes"]
    detail-type = ["PlanAlimenticioGenerado"]
  })
}

resource "aws_cloudwatch_event_target" "lambda_correo" {
  rule           = aws_cloudwatch_event_rule.enviar_correo.name
  event_bus_name = aws_cloudwatch_event_bus.eventos.name
  target_id      = "EnviarCorreoSES"
  arn            = aws_lambda_function.funcion["enviar-correo"].arn
}

resource "aws_sqs_queue" "correos_dlq" {
  name                      = "${local.nombre}-correos-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_lambda_function_event_invoke_config" "correo" {
  function_name                = aws_lambda_function.funcion["enviar-correo"].function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_failure {
      destination = aws_sqs_queue.correos_dlq.arn
    }
  }

  depends_on = [aws_iam_role_policy.lambda]
}

resource "aws_lambda_permission" "eventbridge_correo" {
  statement_id  = "PermitirEventBridgeCorreo"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.funcion["enviar-correo"].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.enviar_correo.arn
}
