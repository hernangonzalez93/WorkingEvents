"""
El punto de entrada de la Lambda: la unica pieza que habla con AWS.

AWS llama a handler() con un LOTE de hasta 10 mensajes de la cola. Por cada uno:
abrir las capas, analizar el texto, decidir, y avisar si hace falta.
"""

import json
import logging
import os

import boto3

from alertas import componer_mensaje, extraer_resenya, requiere_alerta
from analizador import analizar

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Fuera de handler() a proposito
# ---------------------------------------------------------------------------
# Esto se ejecuta UNA vez, cuando AWS arranca el contenedor de la funcion (el
# "arranque en frio"). Despues, el mismo contenedor atiende muchas invocaciones
# seguidas y reutiliza el cliente ya creado. Crearlo dentro de handler()
# repetiria ese trabajo en cada lote.
#
# Sin credenciales, igual que en la API: dentro de Lambda el SDK usa el rol de
# la funcion. Y sin region: Lambda define AWS_REGION por su cuenta.
# ---------------------------------------------------------------------------
sns = boto3.client("sns")
TOPIC_ARN = os.environ["TOPIC_ARN"]


def handler(event, context):
    fallidos = []

    for registro in event["Records"]:
        try:
            procesar(registro)
        except Exception:
            # OJO: infra/alarmas.tf busca este texto EXACTO en los logs para
            # contar los fallos y hacer saltar una alarma. Si se cambia aqui,
            # hay que cambiarlo alli, o la alarma dejara de enterarse.
            logger.exception("Fallo al procesar el mensaje %s", registro.get("messageId"))
            fallidos.append({"itemIdentifier": registro["messageId"]})

    # -----------------------------------------------------------------------
    # Respuesta por lotes parcial
    # -----------------------------------------------------------------------
    # Sin esto, un solo mensaje que falla hace fallar el lote ENTERO, y los
    # otros nueve se reintentan tambien: nueve correos repetidos.
    #
    # Con esto, se le dice a SQS exactamente cuales fallaron. Los demas se
    # borran de la cola y solo los fallidos vuelven a intentarse. Necesita
    # `function_response_types = ["ReportBatchItemFailures"]` en Terraform; sin
    # esa linea, AWS ignora esta respuesta.
    # -----------------------------------------------------------------------
    return {"batchItemFailures": fallidos}


def procesar(registro: dict) -> None:
    resenya = extraer_resenya(registro)
    resultado = analizar(resenya.comentario)
    alerta, motivo = requiere_alerta(resenya, resultado)

    # Una linea JSON por resenya: en CloudWatch se puede filtrar por cualquiera
    # de estos campos, por ejemplo todas las que tuvieron alerta.
    logger.info(json.dumps({
        "resenya": resenya.id,
        "evento": resenya.event_id,
        "calificacion": resenya.calificacion,
        "puntuacion": resultado.puntuacion,
        "sentimiento": resultado.sentimiento,
        "alerta": alerta,
        "motivo": motivo,
    }, ensure_ascii=False))

    if alerta:
        asunto, cuerpo = componer_mensaje(resenya, resultado, motivo)
        sns.publish(TopicArn=TOPIC_ARN, Subject=asunto, Message=cuerpo)
