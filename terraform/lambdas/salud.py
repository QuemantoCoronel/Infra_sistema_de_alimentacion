import os

from comun import respuesta


def handler(event, context):
    return respuesta(
        200,
        {
            "estado": "ok",
            "servicio": "recomendacion-alimenticia",
            "region": os.environ.get("AWS_REGION", "sa-east-1"),
        },
    )
