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

# Versionado: si se sube una versión rota de la web se puede volver a la anterior
resource "aws_s3_bucket_versioning" "web" {
  bucket = aws_s3_bucket.web.id
  versioning_configuration {
    status = "Enabled"
  }
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

# Cliente JS inyectado dinámicamente que conecta las páginas HTML con las rutas de API Gateway
# (GET /salud, GET /perfil, PUT /perfil, POST /planes, GET /planes/{id}, GET /historial, DELETE /datos)
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

    (function() {
      const origFetch = window.fetch.bind(window);
      const apiBase = window.NUTRIPERU_CONFIG.apiUrl;

      function authHeaders(extra) {
        const headers = Object.assign({ "Content-Type": "application/json" }, extra || {});
        const token = localStorage.getItem("np_jwt");
        if (token) headers["Authorization"] = "Bearer " + token;
        return headers;
      }

      function jsonResponse(status, obj) {
        return new Response(JSON.stringify(obj), {
          status: status,
          headers: { "Content-Type": "application/json" }
        });
      }

      window.fetch = async function(input, init) {
        const url = typeof input === "string" ? input : input.url;
        const method = ((init && init.method) || "GET").toUpperCase();

        // 1. POST /api/usuario/entrar -> consulta GET /perfil en API Gateway
        if (url === "/api/usuario/entrar" && method === "POST") {
          const body = JSON.parse((init && init.body) || "{}");
          const username = (body.username || "").trim().toLowerCase();
          const res = await origFetch(apiBase + "/perfil?usuario_id=" + encodeURIComponent(username), {
            method: "GET",
            headers: authHeaders()
          });
          const tienePerfil = res.status === 200;
          return jsonResponse(200, { username: username, tiene_perfil: tienePerfil, nuevo: !tienePerfil });
        }

        // 2. GET/POST /api/usuario/{u}/perfil -> GET /perfil y PUT /perfil en API Gateway
        const mPerfil = url.match(/^\/api\/usuario\/([^/]+)\/perfil$/);
        if (mPerfil) {
          const username = decodeURIComponent(mPerfil[1]);
          if (method === "GET") {
            const res = await origFetch(apiBase + "/perfil?usuario_id=" + encodeURIComponent(username), {
              method: "GET",
              headers: authHeaders()
            });
            if (res.status === 404) {
              return jsonResponse(200, { username: username, tiene_perfil: false });
            }
            const p = await res.json();
            return jsonResponse(200, {
              username: username,
              edad: Number(p.edad),
              sexo: p.sexo,
              peso_kg: Number(p.peso),
              altura_cm: Number(p.talla),
              nivel_actividad: p.actividad,
              objetivo: p.objetivo,
              tiene_perfil: true
            });
          }
          if (method === "POST" || method === "PUT") {
            const b = JSON.parse((init && init.body) || "{}");
            const res = await origFetch(apiBase + "/perfil", {
              method: "PUT",
              headers: authHeaders(),
              body: JSON.stringify({
                usuario_id: username,
                edad: b.edad,
                sexo: b.sexo,
                peso: b.peso_kg || b.peso,
                talla: b.altura_cm || b.talla,
                actividad: b.nivel_actividad || b.actividad,
                objetivo: b.objetivo
              })
            });
            return res;
          }
        }

        // 3. GET /api/usuario/{u}/plan -> POST /planes + polling a GET /planes/{id} y GET /historial
        const mPlan = url.match(/^\/api\/usuario\/([^/]+)\/plan$/);
        if (mPlan && method === "GET") {
          const username = decodeURIComponent(mPlan[1]);
          const resHist = await origFetch(apiBase + "/historial?usuario_id=" + encodeURIComponent(username), {
            method: "GET",
            headers: authHeaders()
          });
          if (resHist.ok) {
            const hist = await resHist.json();
            const generado = (hist.planes || []).find(p => p.estado === "generado" && p.plan_generado);
            if (generado) return jsonResponse(200, generado.plan_generado);
          }
          const resCrear = await origFetch(apiBase + "/planes", {
            method: "POST",
            headers: authHeaders(),
            body: JSON.stringify({ usuario_id: username })
          });
          const creado = await resCrear.json();
          if (!resCrear.ok) return jsonResponse(resCrear.status, creado);
          for (let i = 0; i < 15; i++) {
            await new Promise(r => setTimeout(r, 2000));
            const resPoll = await origFetch(apiBase + "/planes/" + encodeURIComponent(creado.id), {
              method: "GET",
              headers: authHeaders()
            });
            if (resPoll.ok) {
              const item = await resPoll.json();
              if (item.estado === "generado" && item.plan_generado) {
                return jsonResponse(200, item.plan_generado);
              }
            }
          }
          return jsonResponse(202, creado);
        }

        // 4. DELETE /api/usuario/{u}/plan/hoy -> DELETE /datos en API Gateway
        const mBorrar = url.match(/^\/api\/usuario\/([^/]+)\/plan\/hoy$/);
        if (mBorrar && method === "DELETE") {
          const username = decodeURIComponent(mBorrar[1]);
          return origFetch(apiBase + "/datos?usuario_id=" + encodeURIComponent(username), {
            method: "DELETE",
            headers: authHeaders()
          });
        }

        return origFetch(input, init);
      };
    })();
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
