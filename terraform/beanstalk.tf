# Despliegue del backend FastAPI y Panel Académico (/admin) en AWS Elastic Beanstalk

data "aws_elastic_beanstalk_solution_stack" "python" {
  most_recent = true
  name_regex  = "^64bit Amazon Linux 2023 (.*) running Python 3.11$"
}

# Rol IAM para las instancias EC2 de Elastic Beanstalk
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
  name        = "${local.nombre}-eb-app"
  description = "Aplicacion web y panel academico NutriPeru (FastAPI + PuLP + K-Means)"

  appversion_lifecycle {
    service_role          = aws_iam_role.beanstalk_service.arn
    max_count             = 10
    delete_source_from_s3 = true
  }
}

# Empaquetado del código de webapp/ para la versión de Elastic Beanstalk
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

resource "aws_s3_object" "beanstalk_zip" {
  bucket = aws_s3_bucket.web.id
  key    = "beanstalk/nutriperu-${data.archive_file.beanstalk_app.output_md5}.zip"
  source = data.archive_file.beanstalk_app.output_path
  etag   = data.archive_file.beanstalk_app.output_md5
}

resource "aws_elastic_beanstalk_application_version" "actual" {
  name        = "${local.nombre}-v-${substr(data.archive_file.beanstalk_app.output_md5, 0, 8)}"
  application = aws_elastic_beanstalk_application.nutriperu.name
  description = "Version empaquetada automaticamente por Terraform"
  bucket      = aws_s3_bucket.web.id
  key         = aws_s3_object.beanstalk_zip.key
}

# Entorno de ejecución en Elastic Beanstalk
resource "aws_elastic_beanstalk_environment" "env" {
  count               = var.habilitar_beanstalk ? 1 : 0
  name                = "${local.nombre}-eb-env"
  application         = aws_elastic_beanstalk_application.nutriperu.name
  solution_stack_name = data.aws_elastic_beanstalk_solution_stack.python.name
  version_label       = aws_elastic_beanstalk_application_version.actual.name
  tier                = "WebServer"

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     = aws_iam_instance_profile.beanstalk_ec2.name
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "InstanceType"
    value     = var.beanstalk_instance_type
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "RootVolumeType"
    value     = "gp3"
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "DisableIMDSv1"
    value     = "true"
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "EnvironmentType"
    value     = "SingleInstance"
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "ServiceRole"
    value     = aws_iam_role.beanstalk_service.arn
  }

  setting {
    namespace = "aws:elasticbeanstalk:healthreporting:system"
    name      = "SystemType"
    value     = "enhanced"
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions"
    name      = "ManagedActionsEnabled"
    value     = "true"
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions"
    name      = "PreferredStartTime"
    value     = "Sun:06:00"
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions:platformupdate"
    name      = "UpdateLevel"
    value     = "minor"
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "TABLA_PLANES"
    value     = aws_dynamodb_table.planes.name
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "TABLA_PERFILES"
    value     = aws_dynamodb_table.perfiles.name
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "AWS_DEFAULT_REGION"
    value     = var.aws_region
  }
}

