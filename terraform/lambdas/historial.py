import json
import os

import boto3
from boto3.dynamodb.conditions import Key
from comun import extraer_usuario, respuesta

tabla_planes = boto3.resource("dynamodb").Table(os.environ["TABLA_PLANES"])


def handler(event, context):
    usuario_id, _ = extraer_usuario(event)

    respuesta_query = tabla_planes.query(
        IndexName="usuario-index",
        KeyConditionExpression=Key("usuario_id").eq(usuario_id),
        ScanIndexForward=False,
        Limit=20,
    )
    items = respuesta_query.get("Items", [])

    for item in items:
        for campo_json in ("plan_generado", "kmeans", "solicitud"):
            if isinstance(item.get(campo_json), str):
                try:
                    item[campo_json] = json.loads(item[campo_json])
                except json.JSONDecodeError:
                    pass

    return respuesta(
        200,
        {
            "usuario_id": usuario_id,
            "total": len(items),
            "planes": items,
        },
    )

