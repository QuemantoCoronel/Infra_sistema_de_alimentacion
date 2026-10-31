import json
import os
import time
import uuid

import boto3

tabla = boto3.resource("dynamodb").Table(os.environ["TABLA_PLANES"])
sqs = boto3.client("sqs")


def handler(event, context):
    try:
        datos = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _respuesta(400, {"error": "El cuerpo debe ser JSON"})

    faltan = [c for c in ("peso", "talla", "edad", "sexo") if c not in datos]
    if faltan:
        return _respuesta(400, {"error": "Faltan campos", "campos": faltan})

    plan_id = str(uuid.uuid4())
    tabla.put_item(Item={
        "id": plan_id,
        "estado": "pendiente",
        "solicitud": json.dumps(datos),
        "creado": int(time.time()),
    })
    sqs.send_message(
        QueueUrl=os.environ["COLA_URL"],
        MessageBody=json.dumps({"id": plan_id, "datos": datos}),
    )
    return _respuesta(202, {"id": plan_id, "estado": "pendiente"})


def _respuesta(codigo, cuerpo):
    return {
        "statusCode": codigo,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(cuerpo),
    }
