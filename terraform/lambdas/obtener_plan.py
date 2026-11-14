import json
import os

import boto3
from comun import respuesta

tabla = boto3.resource("dynamodb").Table(os.environ["TABLA_PLANES"])


def handler(event, context):
    plan_id = (event.get("pathParameters") or {}).get("id")
    if not plan_id:
        return respuesta(400, {"error": "Falta el id del plan"})

    item = tabla.get_item(Key={"id": plan_id}).get("Item")
    if not item:
        return respuesta(404, {"error": "Plan no encontrado"})

    # Deserializar campos JSON enriquecidos si ya están generados
    for campo_json in ("plan_generado", "kmeans", "solicitud"):
        if isinstance(item.get(campo_json), str):
            try:
                item[campo_json] = json.loads(item[campo_json])
            except json.JSONDecodeError:
                pass

    return respuesta(200, item)
