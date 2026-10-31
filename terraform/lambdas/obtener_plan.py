import json
import os

import boto3

tabla = boto3.resource("dynamodb").Table(os.environ["TABLA_PLANES"])


def handler(event, context):
    plan_id = (event.get("pathParameters") or {}).get("id")
    item = tabla.get_item(Key={"id": plan_id}).get("Item")
    if not item:
        return _respuesta(404, {"error": "Plan no encontrado"})
    return _respuesta(200, item)


def _respuesta(codigo, cuerpo):
    return {
        "statusCode": codigo,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(cuerpo, default=str),
    }
