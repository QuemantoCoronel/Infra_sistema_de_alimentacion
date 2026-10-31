import json
import os

import boto3

tabla = boto3.resource("dynamodb").Table(os.environ["TABLA_PLANES"])

FACTOR_ACTIVIDAD = {
    "sedentario": 1.2,
    "ligero": 1.375,
    "moderado": 1.55,
    "intenso": 1.725,
}


def handler(event, context):
    for registro in event["Records"]:
        mensaje = json.loads(registro["body"])
        datos = mensaje["datos"]

        # TMB con la fórmula de Mifflin-St Jeor
        tmb = 10 * float(datos["peso"]) + 6.25 * float(datos["talla"]) - 5 * int(datos["edad"])
        tmb += 5 if datos["sexo"] == "M" else -161
        get = tmb * FACTOR_ACTIVIDAD.get(datos.get("actividad", "ligero"), 1.375)

        # Aquí irá el optimizador PuLP del motor; por ahora se guarda el requerimiento calórico
        tabla.update_item(
            Key={"id": mensaje["id"]},
            UpdateExpression="SET estado = :e, tmb = :t, calorias_objetivo = :c",
            ExpressionAttributeValues={
                ":e": "generado",
                ":t": str(round(tmb)),
                ":c": str(round(get)),
            },
        )
        print(f"Plan {mensaje['id']} generado: {round(get)} kcal")
