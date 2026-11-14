# Tópico SNS para centralizar las alertas operativas de la infraestructura
resource "aws_sns_topic" "alarmas" {
  name              = "${local.nombre}-alarmas"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "correo_alertas" {
  count     = var.correo_alertas != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarmas.arn
  protocol  = "email"
  endpoint  = var.correo_alertas
}

# Alarma 1: Mensajes acumulados en la cola de errores (DLQ)
resource "aws_cloudwatch_metric_alarm" "dlq_mensajes" {
  alarm_name          = "${local.nombre}-dlq-mensajes-visibles"
  alarm_description   = "Alerta cuando una solicitud supera el maximo de intentos en el worker y cae en la DLQ"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.solicitudes_dlq.name
  }

  alarm_actions = [aws_sns_topic.alarmas.arn]
  ok_actions    = [aws_sns_topic.alarmas.arn]
}

# Alarma 2: Retraso en el procesamiento de la cola SQS por parte del Worker en Elastic Beanstalk
resource "aws_cloudwatch_metric_alarm" "worker_cola_retraso" {
  alarm_name          = "${local.nombre}-worker-cola-retraso"
  alarm_description   = "Alerta cuando hay mensajes sin procesar por mas de 10 minutos en la cola del Worker Beanstalk"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 600
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.solicitudes.name
  }

  alarm_actions = [aws_sns_topic.alarmas.arn]
  ok_actions    = [aws_sns_topic.alarmas.arn]
}

# Alarma 3: Errores 5xx en el API Gateway principal
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.nombre}-api-errores-5xx"
  alarm_description   = "Alerta cuando la API HTTP devuelve errores de servidor 5xx"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "5xx"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = aws_apigatewayv2_api.http.id
  }

  alarm_actions = [aws_sns_topic.alarmas.arn]
  ok_actions    = [aws_sns_topic.alarmas.arn]
}

# Alarma 4: Errores en la Lambda de notificaciones por correo (SES)
resource "aws_cloudwatch_metric_alarm" "correo_errores" {
  alarm_name          = "${local.nombre}-correo-ses-errores"
  alarm_description   = "Alerta cuando falla la función Lambda de envío de correos con SES"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.funcion["enviar-correo"].function_name
  }

  alarm_actions = [aws_sns_topic.alarmas.arn]
  ok_actions    = [aws_sns_topic.alarmas.arn]
}
