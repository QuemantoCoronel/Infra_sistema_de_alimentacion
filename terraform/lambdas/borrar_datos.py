import os

import boto3
from boto3.dynamodb.conditions import Key
from comun import extraer_usuario, respuesta

dynamodb = boto3.resource("dynamodb")
tabla_perfiles = dynamodb.Table(os.environ["TABLA_PERFILES"])
tabla_planes = dynamodb.Table(os.environ["TABLA_PLANES"])


def handler(event, context):
    usuario_id, _ = extraer_usuario(event)

    # 1. Eliminar perfil de la tabla de perfiles
    tabla_perfiles.delete_item(Key={"usuario_id": usuario_id})

    # 2. Consultar y eliminar todos los planes del usuario
    planes = tabla_planes.query(
        IndexName="usuario-index",
        KeyConditionExpression=Key("usuario_id").eq(usuario_id),
    ).get("Items", [])

    eliminados = 0
    with tabla_planes.batch_writer() as batch:
        for p in planes:
            batch.delete_item(Key={"id": p["id"]})
            eliminados += 1

    return respuesta(
        200,
        {
            "mensaje": "Datos del usuario eliminados correctamente",
            "usuario_id": usuario_id,
            "perfil_eliminado": True,
            "planes_eliminados": eliminados,
        },
    )

