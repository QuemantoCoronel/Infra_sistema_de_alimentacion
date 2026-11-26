"""
Lambda de notificación por correo con Amazon SES.
Recibe eventos de EventBridge originados por EventBridge Pipes desde DynamoDB Streams
cuando un plan pasa al estado 'generado'.
"""

import json
import os
import time

import boto3
from botocore.exceptions import ClientError

ses = boto3.client("ses")
tabla_planes = boto3.resource("dynamodb").Table(os.environ["TABLA_PLANES"])


def _marcar_correo(plan_id, estado, detalle=""):
    valores = {":e": estado, ":t": int(time.time())}
    expresion = "SET estado_correo = :e, correo_actualizado = :t"
    if detalle:
        expresion += ", error_correo = :d"
        valores[":d"] = detalle[:500]
    tabla_planes.update_item(
        Key={"id": plan_id},
        UpdateExpression=expresion,
        ExpressionAttributeValues=valores,
    )


def _extraer_imagen_dynamodb(evento):
    """Extrae los campos de NewImage tanto si viene directo del Pipe como envuelto en EventBridge."""
    detalle = evento.get("detail") or evento
    if isinstance(detalle, list) and detalle:
        detalle = detalle[0]
    ddb = detalle.get("dynamodb") or detalle
    nueva_img = ddb.get("NewImage") or {}

    def val(clave, defecto=""):
        nodo = nueva_img.get(clave) or {}
        return nodo.get("S") or nodo.get("N") or defecto

    return {
        "id": val("id", "sin-id"),
        "usuario_id": val("usuario_id", "usuario"),
        "email": val("email", ""),
        "estado": val("estado", ""),
        "tmb": val("tmb", "-"),
        "calorias_objetivo": val("calorias_objetivo", "-"),
        "motor_optimizador": val("motor_optimizador", "PuLP-MILP"),
        "plan_generado": val("plan_generado", "{}"),
    }


def handler(event, context):
    remitente = os.environ.get("CORREO_REMITENTE", "")
    registros = event if isinstance(event, list) else [event]
    enviados = 0

    for reg in registros:
        datos = _extraer_imagen_dynamodb(reg)
        destinatario = datos["email"] or os.environ.get("CORREO_DESTINO_PRUEBA", "") or remitente

        try:
            plan = json.loads(datos["plan_generado"] or "{}")
        except json.JSONDecodeError:
            plan = {}

        platillos = plan.get("nombres_platillos", {})
        resumen_comidas = []
        for comida in ("desayuno", "almuerzo", "cena", "snack"):
            nombre_plato = (platillos.get(comida) or {}).get("nombre", comida.capitalize())
            resumen_comidas.append(f"- {comida.capitalize()}: {nombre_plato}")
        texto_comidas = "\n".join(resumen_comidas) if resumen_comidas else "- Plan de 4 comidas listo"

        asunto = f"NutriPerú — Tu plan alimenticio ({datos['calorias_objetivo']} kcal) está listo"
        cuerpo_texto = (
            f"Hola,\n\n"
            f"Tu plan alimenticio personalizado (ID: {datos['id']}) ha sido generado con éxito.\n\n"
            f"Resumen nutricional:\n"
            f"- TMB: {datos['tmb']} kcal\n"
            f"- Calorías objetivo: {datos['calorias_objetivo']} kcal\n"
            f"- Motor IA: {datos['motor_optimizador']}\n\n"
            f"Menú del día:\n{texto_comidas}\n\n"
            f"¡Buen provecho!\nEquipo NutriPerú"
        )

        if not remitente or not destinatario:
            print(f"Plan {datos['id']}: correo omitido por falta de remitente/destinatario configurado.")
            _marcar_correo(datos["id"], "omitido", "Sin remitente o destinatario")
            continue

        try:
            ses.send_email(
                Source=remitente,
                Destination={"ToAddresses": [destinatario]},
                Message={
                    "Subject": {"Data": asunto, "Charset": "UTF-8"},
                    "Body": {"Text": {"Data": cuerpo_texto, "Charset": "UTF-8"}},
                },
            )
        except ClientError as exc:
            print(f"Error SES para {destinatario} (plan {datos['id']}): {exc}")
            _marcar_correo(datos["id"], "error", str(exc))
            raise

        _marcar_correo(datos["id"], "enviado")
        enviados += 1
        print(f"Correo SES enviado a {destinatario} para el plan {datos['id']}")

    return {"statusCode": 200, "correos_enviados": enviados}

