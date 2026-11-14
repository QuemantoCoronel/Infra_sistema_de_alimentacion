# Firewall de aplicaciones web (AWS WAFv2) asociado a CloudFront (reside en us-east-1)
resource "aws_wafv2_web_acl" "web" {
  provider    = aws.us_east_1
  name        = "${local.nombre}-waf-web"
  description = "WAF para proteger la aplicacion web con limite de 10 000 peticiones y reglas OWASP"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Regla 1: Limitación de tasa a 10 000 peticiones por IP cada 5 minutos (según el informe)
  rule {
    name     = "LimitePeticionesPorIP"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.nombre}-waf-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Regla 2: Reglas administradas por AWS (OWASP Top 10 / Common Rule Set)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.nombre}-waf-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # Regla 3: Bloqueo de entradas maliciosas conocidas
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.nombre}-waf-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.nombre}-waf-web"
    sampled_requests_enabled   = true
  }
}

# Health Checks de Route 53 para monitorear la salud de la región principal (São Paulo) y secundaria
resource "aws_route53_health_check" "api_primaria" {
  fqdn              = replace(aws_apigatewayv2_api.http.api_endpoint, "https://", "")
  port              = 443
  type              = "HTTPS"
  resource_path     = "/salud"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "${local.nombre}-hc-primaria-${var.aws_region}"
  }
}

resource "aws_route53_health_check" "api_secundaria" {
  count             = var.habilitar_multiregion ? 1 : 0
  fqdn              = replace(aws_apigatewayv2_api.http_secundaria[0].api_endpoint, "https://", "")
  port              = 443
  type              = "HTTPS"
  resource_path     = "/salud"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "${local.nombre}-hc-secundaria-${var.aws_region_secundaria}"
  }
}

# Zona hospedada, certificado ACM y Custom Domain en API Gateway cuando se configura var.dominio
resource "aws_route53_zone" "principal" {
  count = var.dominio != "" && var.crear_zona_route53 ? 1 : 0
  name  = var.dominio
}

data "aws_route53_zone" "existente" {
  count        = var.dominio != "" && !var.crear_zona_route53 ? 1 : 0
  name         = var.dominio
  private_zone = false
}

locals {
  route53_zone_id = (
    var.dominio == "" ? "" : (
      var.crear_zona_route53 ? aws_route53_zone.principal[0].zone_id : data.aws_route53_zone.existente[0].zone_id
    )
  )
}

resource "aws_route53_record" "web" {
  count   = var.dominio != "" ? 1 : 0
  zone_id = local.route53_zone_id
  name    = var.dominio
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.web.domain_name
    zone_id                = aws_cloudfront_distribution.web.hosted_zone_id
    evaluate_target_health = false
  }
}

# Certificado ACM y Custom Domain Name en API Gateway (requerido para enrutar api.<dominio> a API Gateway)
resource "aws_acm_certificate" "api_primaria" {
  count             = var.dominio != "" ? 1 : 0
  domain_name       = "api.${var.dominio}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validacion_acm_primaria" {
  for_each = var.dominio != "" ? {
    for dvo in aws_acm_certificate.api_primaria[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = local.route53_zone_id
}

resource "aws_acm_certificate_validation" "api_primaria" {
  count                   = var.dominio != "" ? 1 : 0
  certificate_arn         = aws_acm_certificate.api_primaria[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validacion_acm_primaria : r.fqdn]
}

resource "aws_apigatewayv2_domain_name" "api_primaria" {
  count       = var.dominio != "" ? 1 : 0
  domain_name = "api.${var.dominio}"

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.api_primaria[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "api_primaria" {
  count       = var.dominio != "" ? 1 : 0
  api_id      = aws_apigatewayv2_api.http.id
  domain_name = aws_apigatewayv2_domain_name.api_primaria[0].id
  stage       = aws_apigatewayv2_stage.default.id
}

resource "aws_route53_record" "api_primaria" {
  count           = var.dominio != "" ? 1 : 0
  zone_id         = local.route53_zone_id
  name            = "api.${var.dominio}"
  type            = "A"
  set_identifier  = "primaria-${var.aws_region}"
  health_check_id = aws_route53_health_check.api_primaria.id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = aws_apigatewayv2_domain_name.api_primaria[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.api_primaria[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = true
  }
}

# Custom Domain Name y certificado ACM en la región secundaria para Failover multirregión
resource "aws_acm_certificate" "api_secundaria" {
  provider          = aws.secundaria
  count             = var.dominio != "" && var.habilitar_multiregion ? 1 : 0
  domain_name       = "api.${var.dominio}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "api_secundaria" {
  provider                = aws.secundaria
  count                   = var.dominio != "" && var.habilitar_multiregion ? 1 : 0
  certificate_arn         = aws_acm_certificate.api_secundaria[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validacion_acm_primaria : r.fqdn]
}

resource "aws_apigatewayv2_domain_name" "api_secundaria" {
  provider    = aws.secundaria
  count       = var.dominio != "" && var.habilitar_multiregion ? 1 : 0
  domain_name = "api.${var.dominio}"

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.api_secundaria[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "api_secundaria" {
  provider    = aws.secundaria
  count       = var.dominio != "" && var.habilitar_multiregion ? 1 : 0
  api_id      = aws_apigatewayv2_api.http_secundaria[0].id
  domain_name = aws_apigatewayv2_domain_name.api_secundaria[0].id
  stage       = aws_apigatewayv2_stage.default_secundaria[0].id
}

resource "aws_route53_record" "api_secundaria" {
  count           = var.dominio != "" && var.habilitar_multiregion ? 1 : 0
  zone_id         = local.route53_zone_id
  name            = "api.${var.dominio}"
  type            = "A"
  set_identifier  = "secundaria-${var.aws_region_secundaria}"
  health_check_id = aws_route53_health_check.api_secundaria[0].id

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = aws_apigatewayv2_domain_name.api_secundaria[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.api_secundaria[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = true
  }
}
