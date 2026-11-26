import os

import boto3
from comun import extraer_usuario, respuesta

tabla_perfiles = boto3.resource("dynamodb").Table(os.environ["TABLA_PERFILES"])


def handler(event, context):
    usuario_id, _ = extraer_usuario(event)
    item = tabla_perfiles.get_item(Key={"usuario_id": usuario_id}).get("Item")
    if not item:
        return respuesta(404, {"error": "Perfil no encontrado", "usuario_id": usuario_id})
    return respuesta(200, item)

