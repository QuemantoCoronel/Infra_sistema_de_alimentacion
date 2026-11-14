import json
import os
import time

import boto3
from motor_ia import generar_plan_completo

tabla = boto3.resource("dynamodb").Table(os.environ["TABLA_PLANES"])


def handler(event, context):
    for registro in event["Records"]:
        mensaje = json.loads(registro["body"])
        plan_id = mensaje["id"]
        datos = mensaje["datos"]

        resultado = generar_plan_completo(datos)
        targets = resultado["targets_dia"]

        tabla.update_item(
            Key={"id": plan_id},
            UpdateExpression=(
                "SET estado = :e, "
                "tmb = :tmb, "
                "calorias_objetivo = :cal, "
                "motor_optimizador = :m, "
                "kmeans = :km, "
                "plan_generado = :pg, "
                "actualizado = :act"
            ),
            ExpressionAttributeValues={
                ":e": "generado",
                ":tmb": str(targets["tmb"]),
                ":cal": str(targets["calorias_objetivo"]),
                ":m": resultado["motor_optimizador"],
                ":km": json.dumps(resultado["kmeans"], ensure_ascii=False),
                ":pg": json.dumps(resultado, ensure_ascii=False),
                ":act": int(time.time()),
            },
        )
        print(
            f"Plan {plan_id} generado con {resultado['motor_optimizador']} "
            f"y {resultado['kmeans']['motor']}: {targets['calorias_objetivo']} kcal"
        )
