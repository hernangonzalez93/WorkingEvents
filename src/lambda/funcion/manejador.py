"""
El punto de entrada de la Lambda: la unica pieza que habla con AWS.

AWS llama a handler() con un LOTE de mensajes de la cola. Por cada uno: abrir las
capas, analizar el texto, decidir, y avisar si hace falta.
"""

import json
import logging
import os

import boto3

import analizador_llm
import secretos
from alertas import Resenya, componer_mensaje, extraer_resenya, requiere_alerta
from analizador import Resultado, analizar

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

# Quien analiza el texto, segun decida Terraform (variable proveedor_analisis):
#   "lexico"     el analizador propio, sin IA y sin coste
#   "anthropic"  Claude, con la clave del secreto SECRETO_ID
#   "openai"     GPT, con la clave del secreto SECRETO_ID
PROVEEDOR = os.environ.get("PROVEEDOR_ANALISIS", "lexico")
MODELO = os.environ.get("MODELO", "")
SECRETO_ID = os.environ.get("SECRETO_ID", "")


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
    # otros se reintentan tambien: correos repetidos.
    #
    # Con esto, se le dice a SQS exactamente cuales fallaron. Los demas se
    # borran de la cola y solo los fallidos vuelven a intentarse. Necesita
    # `function_response_types = ["ReportBatchItemFailures"]` en Terraform; sin
    # esa linea, AWS ignora esta respuesta.
    # -----------------------------------------------------------------------
    return {"batchItemFailures": fallidos}


def analizar_resenya(resenya: Resenya) -> Resultado:
    if PROVEEDOR == "lexico":
        return analizar(resenya.comentario)

    try:
        clave = secretos.leer(SECRETO_ID)
        return analizador_llm.ANALIZADORES[PROVEEDOR](resenya.comentario, resenya.calificacion, clave, MODELO)
    except Exception as error:
        # -------------------------------------------------------------------
        # El respaldo: si la IA falla, analiza el lexico
        # -------------------------------------------------------------------
        # El proveedor es una dependencia EXTERNA: puede estar caido, la clave
        # puede haber caducado, el secreto puede estar vacio... Dejar de
        # analizar resenyas por eso seria peor que analizarlas peor. Asi que
        # se analiza con el lexico, y el correo dice con que se analizo.
        #
        # Pero sin esconderlo: esta linea la cuenta un filtro de metricas y
        # hace saltar una alarma (infra/alarmas.tf busca este texto EXACTO).
        # Se registra el tipo de error y el codigo HTTP, nunca el mensaje
        # completo: algunos proveedores repiten en el una parte de la clave.
        # -------------------------------------------------------------------
        logger.warning(
            "Analisis degradado: %s fallo con %s (HTTP %s). Se usa el lexico.",
            PROVEEDOR, type(error).__name__, getattr(error, "status_code", "-"),
        )
        resultado = analizar(resenya.comentario)
        resultado.motor = f"lexico (respaldo: {PROVEEDOR} fallo)"
        return resultado


def procesar(registro: dict) -> None:
    resenya = extraer_resenya(registro)
    resultado = analizar_resenya(resenya)
    alerta, motivo = requiere_alerta(resenya, resultado)

    # Una linea JSON por resenya: en CloudWatch se puede filtrar por cualquiera
    # de estos campos, por ejemplo todas las que tuvieron alerta.
    logger.info(json.dumps({
        "resenya": resenya.id,
        "evento": resenya.event_id,
        "calificacion": resenya.calificacion,
        "motor": resultado.motor,
        "sentimiento": resultado.sentimiento,
        "urgencia": resultado.urgencia,
        "puntuacion": resultado.puntuacion,
        "tokens": [resultado.tokens_entrada, resultado.tokens_salida],
        "alerta": alerta,
        "motivo": motivo,
    }, ensure_ascii=False))

    if alerta:
        asunto, cuerpo = componer_mensaje(resenya, resultado, motivo)
        sns.publish(TopicArn=TOPIC_ARN, Subject=asunto, Message=cuerpo)
