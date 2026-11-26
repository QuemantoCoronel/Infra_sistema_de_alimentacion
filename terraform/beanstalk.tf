# Worker en AWS Elastic Beanstalk: ejecuta el motor real (PuLP MILP + scikit-learn K-Means + 15 reglas)
# consumiendo mensajes de la cola SQS y guardando el plan generado en DynamoDB.

data "aws_elastic_beanstalk_solution_stack" "python" {
  most_recent = true
  name_regex  = "^64bit Amazon Linux 2023 (.*) running Python 3.11$"
}

# Rol IAM para las instancias EC2 del Worker en Elastic Beanstalk
data "aws_iam_policy_document" "beanstalk_ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "beanstalk_ec2" {
  name               = "${local.nombre}-beanstalk-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.beanstalk_ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "beanstalk_web_tier" {
  role       = aws_iam_role.beanstalk_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier"
}

resource "aws_iam_role_policy_attachment" "beanstalk_worker_tier" {
  role       = aws_iam_role.beanstalk_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkWorkerTier"
}

data "aws_iam_policy_document" "beanstalk_worker_permisos" {
  statement {
    sid = "ConsumirColaSolicitudesSQS"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [
      aws_sqs_queue.solicitudes.arn,
      aws_sqs_queue.solicitudes_dlq.arn,
    ]
  }

  statement {
    sid = "ActualizarPlanesEnDynamoDB"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
    ]
    resources = [
      aws_dynamodb_table.planes.arn,
      aws_dynamodb_table.perfiles.arn,
    ]
  }

  statement {
    sid       = "LeerSecretosWorker"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app.arn]
  }
}

resource "aws_iam_role_policy" "beanstalk_worker_permisos" {
  name   = "${local.nombre}-beanstalk-worker-permisos"
  role   = aws_iam_role.beanstalk_ec2.id
  policy = data.aws_iam_policy_document.beanstalk_worker_permisos.json
}

resource "aws_iam_instance_profile" "beanstalk_ec2" {
  name = "${local.nombre}-beanstalk-ec2-profile"
  role = aws_iam_role.beanstalk_ec2.name
}

# Rol de servicio IAM para que Elastic Beanstalk monitoree salud y aplique actualizaciones
data "aws_iam_policy_document" "beanstalk_service_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["elasticbeanstalk.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "beanstalk_service" {
  name               = "${local.nombre}-beanstalk-service-role"
  assume_role_policy = data.aws_iam_policy_document.beanstalk_service_assume.json
}

resource "aws_iam_role_policy_attachment" "beanstalk_enhanced_health" {
  role       = aws_iam_role.beanstalk_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth"
}

resource "aws_iam_role_policy_attachment" "beanstalk_managed_updates" {
  role       = aws_iam_role.beanstalk_service.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy"
}

# Aplicación en Elastic Beanstalk
resource "aws_elastic_beanstalk_application" "nutriperu" {
  name        = "${local.nombre}-worker-eb"
  description = "Worker de IA NutriPeru (PuLP MILP + K-Means + Sistema Experto)"

  appversion_lifecycle {
    service_role          = aws_iam_role.beanstalk_service.arn
    max_count             = 10
    delete_source_from_s3 = true
  }
}

# Empaquetado del código de webapp/ y data/ingredientes_dataset.csv para Elastic Beanstalk
data "archive_file" "beanstalk_app" {
  type        = "zip"
  output_path = "${path.module}/build/beanstalk_app.zip"
  source_dir  = "${path.module}/.."
  excludes = [
    ".git",
    ".github",
    "terraform",
    "notebooks",
    "result.xml",
    "captura_checkov.png",
    "reporte_checkov.pdf",
    "__pycache__",
  ]
}

resource "aws_s3_bucket" "versiones_worker" {
  bucket        = "${local.nombre}-versiones-worker-${data.aws_caller_identity.actual.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "versiones_worker" {
  bucket                  = aws_s3_bucket.versiones_worker.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "versiones_worker" {
  bucket = aws_s3_bucket.versiones_worker.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "beanstalk_zip" {
  bucket = aws_s3_bucket.versiones_worker.id
  key    = "beanstalk/nutriperu-${data.archive_file.beanstalk_app.output_md5}.zip"
  source = data.archive_file.beanstalk_app.output_path
  etag   = data.archive_file.beanstalk_app.output_md5
}

resource "aws_elastic_beanstalk_application_version" "actual" {
  name        = "${local.nombre}-v-${substr(data.archive_file.beanstalk_app.output_md5, 0, 8)}"
  application = aws_elastic_beanstalk_application.nutriperu.name
  description = "Version del Worker (PuLP + K-Means) empaquetada por Terraform"
  bucket      = aws_s3_bucket.versiones_worker.id
  key         = aws_s3_object.beanstalk_zip.key
}

locals {
  ajustes_worker = [
    ["aws:ec2:vpc", "VPCId", aws_vpc.worker.id],
    ["aws:ec2:vpc", "Subnets", join(",", aws_subnet.publica[*].id)],
    ["aws:ec2:vpc", "AssociatePublicIpAddress", "true"],
    ["aws:autoscaling:launchconfiguration", "IamInstanceProfile", aws_iam_instance_profile.beanstalk_ec2.name],
    ["aws:autoscaling:launchconfiguration", "InstanceType", var.beanstalk_instance_type],
    ["aws:autoscaling:launchconfiguration", "RootVolumeType", "gp3"],
    ["aws:autoscaling:launchconfiguration", "DisableIMDSv1", "true"],
    ["aws:autoscaling:asg", "MinSize", tostring(var.worker_min_instancias)],
    ["aws:autoscaling:asg", "MaxSize", tostring(var.worker_max_instancias)],
    ["aws:autoscaling:trigger", "MeasureName", "CPUUtilization"],
    ["aws:autoscaling:trigger", "Statistic", "Average"],
    ["aws:autoscaling:trigger", "Unit", "Percent"],
    ["aws:autoscaling:trigger", "Period", "1"],
    ["aws:autoscaling:trigger", "BreachDuration", "1"],
    ["aws:autoscaling:trigger", "UpperThreshold", "60"],
    ["aws:autoscaling:trigger", "LowerThreshold", "20"],
    ["aws:elasticbeanstalk:environment", "ServiceRole", aws_iam_role.beanstalk_service.arn],
    ["aws:elasticbeanstalk:healthreporting:system", "SystemType", "enhanced"],
    ["aws:elasticbeanstalk:cloudwatch:logs", "StreamLogs", "true"],
    ["aws:elasticbeanstalk:cloudwatch:logs", "RetentionInDays", "365"],
    ["aws:elasticbeanstalk:managedactions", "ManagedActionsEnabled", "true"],
    ["aws:elasticbeanstalk:managedactions", "PreferredStartTime", "Sun:06:00"],
    ["aws:elasticbeanstalk:managedactions:platformupdate", "UpdateLevel", "minor"],
    ["aws:elasticbeanstalk:sqsd", "WorkerQueueURL", aws_sqs_queue.solicitudes.url],
    ["aws:elasticbeanstalk:sqsd", "HttpPath", "/worker/procesar"],
    ["aws:elasticbeanstalk:sqsd", "MimeType", "application/json"],
    ["aws:elasticbeanstalk:sqsd", "HttpConnections", "2"],
    ["aws:elasticbeanstalk:sqsd", "VisibilityTimeout", tostring(var.sqs_visibility_timeout)],
    ["aws:elasticbeanstalk:sqsd", "InactivityTimeout", "120"],
    ["aws:elasticbeanstalk:sqsd", "MaxRetries", tostring(var.sqs_max_receive_count)],
    ["aws:elasticbeanstalk:application:environment", "TABLA_PLANES", aws_dynamodb_table.planes.name],
    ["aws:elasticbeanstalk:application:environment", "TABLA_PERFILES", aws_dynamodb_table.perfiles.name],
    ["aws:elasticbeanstalk:application:environment", "SECRETO_ARN", aws_secretsmanager_secret.app.arn],
    ["aws:elasticbeanstalk:application:environment", "AWS_DEFAULT_REGION", var.aws_region],
  ]
}

resource "aws_elastic_beanstalk_environment" "env" {
  count               = var.habilitar_beanstalk ? 1 : 0
  name                = "${local.nombre}-worker-env"
  application         = aws_elastic_beanstalk_application.nutriperu.name
  solution_stack_name = data.aws_elastic_beanstalk_solution_stack.python.name
  version_label       = aws_elastic_beanstalk_application_version.actual.name
  tier                = "Worker"

  dynamic "setting" {
    for_each = local.ajustes_worker
    content {
      namespace = setting.value[0]
      name      = setting.value[1]
      value     = setting.value[2]
    }
  }

  depends_on = [aws_route_table_association.publica]
}
