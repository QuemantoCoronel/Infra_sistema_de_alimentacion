# Rol de ejecución que usan las funciones Lambda
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${local.nombre}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_permisos" {
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.actual.account_id}:log-group:/aws/lambda/${local.nombre}-*:*",
      "arn:aws:logs:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:log-group:/aws/lambda/${local.nombre}-*:*",
    ]
  }

  statement {
    sid = "TablasDynamoDB"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:BatchWriteItem",
    ]
    resources = [
      aws_dynamodb_table.planes.arn,
      "${aws_dynamodb_table.planes.arn}/index/*",
      "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.planes.name}",
      "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.planes.name}/index/*",
      aws_dynamodb_table.perfiles.arn,
      "arn:aws:dynamodb:${var.aws_region_secundaria}:${data.aws_caller_identity.actual.account_id}:table/${aws_dynamodb_table.perfiles.name}",
    ]
  }

  statement {
    sid = "ColaSolicitudes"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.solicitudes.arn]
  }

  statement {
    sid       = "EnvioCorreosSES"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_permisos" {
  name   = "${local.nombre}-lambda-permisos"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_permisos.json
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

data "aws_caller_identity" "actual" {}
