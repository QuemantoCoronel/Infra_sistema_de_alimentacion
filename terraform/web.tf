# Bucket S3 privado donde se aloja el frontend estático de NutriPerú
resource "aws_s3_bucket" "web" {
  bucket        = "${local.nombre}-web-${data.aws_caller_identity.actual.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Origin Access Control (OAC) para que solo CloudFront pueda leer del bucket S3
resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${local.nombre}-web-oac"
  description                       = "Control de acceso de origen para el bucket S3 de la web"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  archivos_estaticos = {
    "index.html"        = "text/html; charset=utf-8"
    "perfil.html"       = "text/html; charset=utf-8"
    "ingredientes.html" = "text/html; charset=utf-8"
    "plan.html"         = "text/html; charset=utf-8"
    "admin.html"        = "text/html; charset=utf-8"
    "style.css"         = "text/css; charset=utf-8"
  }
}

resource "aws_s3_object" "web" {
  for_each = local.archivos_estaticos

  bucket       = aws_s3_bucket.web.id
  key          = each.key
  source       = "${path.module}/../webapp/static/${each.key}"
  content_type = each.value
  etag         = filemd5("${path.module}/../webapp/static/${each.key}")
}

# Archivo de configuración inyectado dinámicamente con los endpoints de AWS desplegados
resource "aws_s3_object" "config_js" {
  bucket       = aws_s3_bucket.web.id
  key          = "config.js"
  content_type = "application/javascript; charset=utf-8"
  content      = <<-EOT
    window.NUTRIPERU_CONFIG = {
      apiUrl: "${aws_apigatewayv2_api.http.api_endpoint}",
      apiSecundariaUrl: "${var.habilitar_multiregion ? aws_apigatewayv2_api.http_secundaria[0].api_endpoint : ""}",
      cognitoUserPoolId: "${aws_cognito_user_pool.usuarios.id}",
      cognitoClientId: "${aws_cognito_user_pool_client.web.id}",
      regionPrincipal: "${var.aws_region}",
      regionSecundaria: "${var.aws_region_secundaria}"
    };
  EOT
}

# Función de CloudFront para resolver rutas limpias (/perfil -> /perfil.html, /static/style.css -> /style.css)
resource "aws_cloudfront_function" "rutas_limpias" {
  name    = "${local.nombre}-rutas-limpias"
  runtime = "cloudfront-js-2.0"
  comment = "Reescribe rutas limpias de la web estática hacia sus archivos en S3"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      if (uri.startsWith('/static/')) {
        request.uri = uri.replace('/static/', '/');
      } else if (uri === '/perfil' || uri === '/plan' || uri === '/ingredientes' || uri === '/admin') {
        request.uri = uri + '.html';
      } else if (uri.endsWith('/')) {
        request.uri += 'index.html';
      }
      return request;
    }
  EOT
}

# Distribución global de CloudFront protegida con AWS WAFv2
resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Frontend NutriPeru (${local.nombre})"
  default_root_object = "index.html"
  price_class         = "PriceClass_All"
  web_acl_id          = aws_wafv2_web_acl.web.arn

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "s3-web"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  origin {
    domain_name = replace(aws_apigatewayv2_api.http.api_endpoint, "https://", "")
    origin_id   = "api-primaria"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-web"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rutas_limpias.arn
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/salud"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "api-primaria"
    viewer_protocol_policy = "https-only"
    default_ttl            = 0
    min_ttl                = 0
    max_ttl                = 0

    forwarded_values {
      query_string = true
      headers      = ["Authorization"]
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "politica_bucket_web" {
  statement {
    sid       = "PermitirLecturaCloudFrontOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.politica_bucket_web.json
}
