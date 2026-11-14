import json


def respuesta(codigo, cuerpo):
    return {
        "statusCode": codigo,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
        },
        "body": json.dumps(cuerpo, default=str, ensure_ascii=False),
    }


def extraer_usuario(event, datos_cuerpo=None):
    """Extrae usuario_id y email del token JWT de Cognito (o del cuerpo/query como respaldo)."""
    claims = (
        (event.get("requestContext") or {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )
    query = event.get("queryStringParameters") or {}
    cuerpo = datos_cuerpo or {}

    usuario_id = (
        claims.get("sub")
        or claims.get("cognito:username")
        or claims.get("username")
        or cuerpo.get("usuario_id")
        or query.get("usuario_id")
        or "anonimo"
    )
    email = (
        claims.get("email")
        or cuerpo.get("email")
        or query.get("email")
        or ""
    )
    return str(usuario_id), str(email)

