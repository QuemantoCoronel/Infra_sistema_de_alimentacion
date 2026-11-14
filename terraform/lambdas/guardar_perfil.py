import json
import os
import time

import boto3
from comun import extraer_usuario, respuesta

tabla_perfiles = boto3.resource("dynamodb").Table(os.environ["TABLA_PERFILES"])


def handler(event, context):
    try:
        datos = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return respuesta(400, {"error": "El cuerpo debe ser JSON"})

    faltan = [c for c in ("peso", "talla", "edad", "sexo") if c not in datos]
    if faltan:
        return respuesta(400, {"error": "Faltan campos del perfil", "campos": faltan})

    usuario_id, email = extraer_usuario(event, datos)

    perfil = {
        "usuario_id": usuario_id,
        "peso": str(datos["peso"]),
        "talla": str(datos["talla"]),
        "edad": int(datos["edad"]),
        "sexo": str(datos["sexo"]).upper(),
        "actividad": datos.get("actividad", datos.get("nivel_actividad", "ligero")),
        "objetivo": datos.get("objetivo", "mantener"),
        "ingredientes": datos.get("ingredientes", []),
        "actualizado": int(time.time()),
    }
    if email:
        perfil["email"] = email

    tabla_perfiles.put_item(Item=perfil)
    return respuesta(200, {"mensaje": "Perfil guardado", "perfil": perfil})

