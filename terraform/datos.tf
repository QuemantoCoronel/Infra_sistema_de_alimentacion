# Tabla donde se guardan las solicitudes y los planes generados
resource "aws_dynamodb_table" "planes" {
  name         = "${local.nombre}-planes"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# Cola que desacopla la API del worker que genera el plan
resource "aws_sqs_queue" "solicitudes_dlq" {
  name                      = "${local.nombre}-solicitudes-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "solicitudes" {
  name                       = "${local.nombre}-solicitudes"
  visibility_timeout_seconds = 90
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.solicitudes_dlq.arn
    maxReceiveCount     = 3
  })
}
