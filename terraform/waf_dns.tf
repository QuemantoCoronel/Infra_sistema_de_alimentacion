# Firewall de aplicaciones web (AWS WAFv2) asociado a CloudFront (debe residir en us-east-1)
resource "aws_wafv2_web_acl" "web" {
  provider    = aws.us_east_1
  name        = "${local.nombre}-waf-web"
  description = "WAF para proteger la aplicacion web y el trafico hacia la API"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Regla 1: Limitación de tasa por IP para mitigar ataques de fuerza bruta y DDoS
  rule {
    name     = "LimitePeticionesPorIP"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
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

# Zona hospedada y registros DNS con Failover en Route 53 (opcionales si se configura var.dominio)
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

resource "aws_route53_record" "api_primaria" {
  count           = var.dominio != "" ? 1 : 0
  zone_id         = local.route53_zone_id
  name            = "api.${var.dominio}"
  type            = "CNAME"
  ttl             = 60
  set_identifier  = "primaria-${var.aws_region}"
  health_check_id = aws_route53_health_check.api_primaria.id

  failover_routing_policy {
    type = "PRIMARY"
  }

  records = [replace(aws_apigatewayv2_api.http.api_endpoint, "https://", "")]
}

resource "aws_route53_record" "api_secundaria" {
  count           = var.dominio != "" && var.habilitar_multiregion ? 1 : 0
  zone_id         = local.route53_zone_id
  name            = "api.${var.dominio}"
  type            = "CNAME"
  ttl             = 60
  set_identifier  = "secundaria-${var.aws_region_secundaria}"
  health_check_id = aws_route53_health_check.api_secundaria[0].id

  failover_routing_policy {
    type = "SECONDARY"
  }

  records = [replace(aws_apigatewayv2_api.http_secundaria[0].api_endpoint, "https://", "")]
}

