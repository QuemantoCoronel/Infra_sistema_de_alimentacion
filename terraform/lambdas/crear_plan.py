import json
import os
import time
import uuid
from decimal import Decimal

import boto3
from comun import extraer_usuario, respuesta

dynamodb = boto3.resource("dynamodb")
tabla_planes = dynamodb.Table(os.environ["TABLA_PLANES"])
tabla_perfiles = dynamodb.Table(os.environ["TABLA_PERFILES"])
sqs = boto3.client("sqs")


def _sin_decimal(valor):
    if isinstance(valor, Decimal):
        return int(valor) if valor % 1 == 0 else float(valor)
    if isinstance(valor, list):
        return [_sin_decimal(v) for v in valor]
    return valor


def handler(event, context):
    try:
        datos = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return respuesta(400, {"error": "El cuerpo debe ser JSON"})

    usuario_id, email = extraer_usuario(event, datos)

    # Si faltan campos en el POST pero el usuario ya tiene perfil guardado, completar desde TABLA_PERFILES
    faltan_inicial = [c for c in ("peso", "talla", "edad", "sexo") if c not in datos]
    if faltan_inicial and usuario_id != "anonimo":
        perfil = tabla_perfiles.get_item(Key={"usuario_id": usuario_id}).get("Item")
        if perfil:
            for campo in ("peso", "talla", "edad", "sexo", "actividad", "objetivo", "ingredientes"):
                if campo not in datos and campo in perfil:
                    datos[campo] = _sin_decimal(perfil[campo])
            if not email and perfil.get("email"):
                email = perfil["email"]

    faltan = [c for c in ("peso", "talla", "edad", "sexo") if c not in datos]
    if faltan:
        return respuesta(400, {"error": "Faltan campos", "campos": faltan})

    plan_id = str(uuid.uuid4())
    ahora = int(time.time())

    item = {
        "id": plan_id,
        "usuario_id": usuario_id,
        "estado": "pendiente",
        "solicitud": json.dumps(datos, ensure_ascii=False),
        "creado": ahora,
    }
    if email:
        item["email"] = email

    tabla_planes.put_item(Item=item)
    sqs.send_message(
        QueueUrl=os.environ["COLA_URL"],
        MessageBody=json.dumps({"id": plan_id, "usuario_id": usuario_id, "datos": datos}),
    )
    return respuesta(202, {"id": plan_id, "usuario_id": usuario_id, "estado": "pendiente"})
