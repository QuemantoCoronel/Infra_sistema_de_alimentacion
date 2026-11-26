data "aws_caller_identity" "actual" {}

# Asunción de rol para funciones AWS Lambda
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Un rol de ejecución IAM independiente por cada función Lambda (principio de mínimo privilegio)
resource "aws_iam_role" "lambda" {
  for_each           = local.funciones
  name               = "${local.nombre}-role-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

locals {
  permisos_por_funcion = {
    salud = []
    crear-plan = [
      {
        sid       = "GuardarPlanPendiente"
        actions   = ["dynamodb:PutItem"]
        resources = [aws_dynamodb_table.planes.arn]
      },
      {
        sid       = "LeerPerfilUsuario"
        actions   = ["dynamodb:GetItem"]
        resources = [aws_dynamodb_table.perfiles.arn]
      },
      {
        sid       = "EncolarSolicitudSQS"
        actions   = ["sqs:SendMessage"]
        resources = [aws_sqs_queue.solicitudes.arn]
      },
    ]
    obtener-plan = [
      {
        sid     = "ObtenerPlanPorId"
        actions = ["dynamodb:GetItem"]
        resources = [
          aws_dynamodb_table.planes.arn,
          "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.planes.name}",
        ]
      },
    ]
    guardar-perfil = [
      {
        sid     = "GuardarPerfilEnDynamoDB"
        actions = ["dynamodb:PutItem"]
        resources = [
          aws_dynamodb_table.perfiles.arn,
          "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.perfiles.name}",
        ]
      },
    ]
    obtener-perfil = [
      {
        sid     = "LeerPerfilEnDynamoDB"
        actions = ["dynamodb:GetItem"]
        resources = [
          aws_dynamodb_table.perfiles.arn,
          "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.perfiles.name}",
        ]
      },
    ]
    historial = [
      {
        sid     = "ConsultarHistorialPorUsuario"
        actions = ["dynamodb:Query"]
        resources = [
          aws_dynamodb_table.planes.arn,
          "${aws_dynamodb_table.planes.arn}/index/usuario-index",
          "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.planes.name}",
          "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.planes.name}/index/usuario-index",
        ]
      },
    ]
    borrar-datos = [
      {
        sid     = "EliminarPerfilYPlanesUsuario"
        actions = ["dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:BatchWriteItem"]
        resources = [
          aws_dynamodb_table.perfiles.arn,
          aws_dynamodb_table.planes.arn,
          "${aws_dynamodb_table.planes.arn}/index/usuario-index",
          "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.perfiles.name}",
          "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.planes.name}",
          "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.planes.name}/index/usuario-index",
        ]
      },
    ]
    enviar-correo = [
      {
        sid     = "EnviarCorreoSES"
        actions = ["ses:SendEmail", "ses:SendRawEmail"]
        resources = [
          "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.actual.account_id}:identity/*",
        ]
      },
      {
        sid       = "LeerSecretoAplicacion"
        actions   = ["secretsmanager:GetSecretValue"]
        resources = [aws_secretsmanager_secret.app.arn]
      },
      {
        sid       = "MarcarEstadoCorreo"
        actions   = ["dynamodb:UpdateItem"]
        resources = [aws_dynamodb_table.planes.arn]
      },
      {
        sid       = "EnviarFallosCorreoDLQ"
        actions   = ["sqs:SendMessage"]
        resources = [aws_sqs_queue.correos_dlq.arn]
      },
    ]
  }
}

data "aws_iam_policy_document" "lambda_por_funcion" {
  for_each = local.funciones

  statement {
    sid     = "LogsFuncion"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.actual.account_id}:log-group:/aws/lambda/${local.nombre}-${each.key}:*",
      "arn:aws:logs:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:log-group:/aws/lambda/${local.nombre}-${each.key}:*",
    ]
  }

  statement {
    sid       = "TrazasXRay"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = local.permisos_por_funcion[each.key]
    content {
      sid       = statement.value.sid
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  for_each = local.funciones
  name     = "${local.nombre}-policy-${each.key}"
  role     = aws_iam_role.lambda[each.key].id
  policy   = data.aws_iam_policy_document.lambda_por_funcion[each.key].json
}

# Rol de ejecución para EventBridge Pipes (DynamoDB Stream -> EventBridge Bus)
data "aws_iam_policy_document" "pipes_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["pipes.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipes_exec" {
  name               = "${local.nombre}-pipes-exec"
  assume_role_policy = data.aws_iam_policy_document.pipes_assume.json
}

data "aws_iam_policy_document" "pipes_permisos" {
  statement {
    sid = "LeerStreamPlanes"
    actions = [
      "dynamodb:DescribeStream",
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:ListStreams",
    ]
    resources = [aws_dynamodb_table.planes.stream_arn]
  }

  statement {
    sid       = "PublicarEnEventBridge"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.eventos.arn]
  }
}

resource "aws_iam_role_policy" "pipes_permisos" {
  name   = "${local.nombre}-pipes-permisos"
  role   = aws_iam_role.pipes_exec.id
  policy = data.aws_iam_policy_document.pipes_permisos.json
}