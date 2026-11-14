# Tabla Global donde se guardan las solicitudes y los planes generados
resource "aws_dynamodb_table" "planes" {
  name             = "${local.nombre}-planes"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "id"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "usuario_id"
    type = "S"
  }

  attribute {
    name = "creado"
    type = "N"
  }

  global_secondary_index {
    name            = "usuario-index"
    projection_type = "ALL"

    key_schema {
      attribute_name = "usuario_id"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "creado"
      key_type       = "RANGE"
    }
  }

  dynamic "replica" {
    for_each = var.habilitar_multiregion ? [var.aws_region_secundaria] : []
    content {
      region_name = replica.value
    }
  }
}

# Tabla Global donde se guardan los perfiles nutricionales de cada usuario
resource "aws_dynamodb_table" "perfiles" {
  name             = "${local.nombre}-perfiles"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "usuario_id"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "usuario_id"
    type = "S"
  }

  dynamic "replica" {
    for_each = var.habilitar_multiregion ? [var.aws_region_secundaria] : []
    content {
      region_name = replica.value
    }
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
