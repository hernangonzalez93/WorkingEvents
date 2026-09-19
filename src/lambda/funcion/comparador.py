"""
Compara los motores de analisis sobre las mismas resenyas. NO envia correos.

Es una SEGUNDA Lambda (workingevents-comparador) con el mismo paquete de codigo
que la analizadora, pero con otra puerta de entrada: este handler() en vez del
de manejador.py. Y con otro rol, que solo puede leer los secretos: ni cola, ni
SNS.

Por que en AWS y no en tu equipo: asi las claves nunca salen de AWS, y se prueba
exactamente el mismo codigo y las mismas librerias que usara la analizadora.

Cada motor se escribe como "lexico", "openai" (el modelo que diga Terraform) o
"openai:gpt-5.6-luna" (cualquier otro modelo del mismo proveedor). Asi se pueden
comparar dos modelos entre si sin tocar Terraform.

Se invoca a mano, con src/lambda/comparar.py o directamente con:
    aws lambda invoke --function-name workingevents-comparador \
        --payload fileb://pruebas/comparacion.json salida.json
"""

import os
import time

import analizador_llm
import secretos
from analizador import analizar

# Para cada proveedor, que secreto y que modelo usar. Lo rellena Terraform.
CONFIGURACION = {
    "anthropic": (os.environ.get("SECRETO_ANTHROPIC", ""), os.environ.get("MODELO_ANTHROPIC", "")),
    "openai": (os.environ.get("SECRETO_OPENAI", ""), os.environ.get("MODELO_OPENAI", "")),
}


def handler(event, context):
    motores = event.get("motores") or ["lexico"] + [p for p, (secreto, _) in CONFIGURACION.items() if secreto]

    filas = []
    for resenya in event["resenyas"]:
        fila = {"comentario": resenya["comentario"], "calificacion": resenya["calificacion"]}
        for motor in motores:
            fila[motor] = _analizar(motor, resenya["comentario"], resenya["calificacion"])
        filas.append(fila)
    return filas


def _analizar(motor: str, comentario: str, calificacion: int) -> dict:
    # "openai:gpt-5.6-luna" -> proveedor "openai", modelo "gpt-5.6-luna".
    # "openai" a secas -> el modelo que tenga configurado.
    proveedor, _, modelo_pedido = motor.partition(":")

    inicio = time.monotonic()
    try:
        if proveedor == "lexico":
            resultado = analizar(comentario)
        else:
            secreto, modelo = CONFIGURACION[proveedor]
            resultado = analizador_llm.ANALIZADORES[proveedor](
                comentario, calificacion, secretos.leer(secreto), modelo_pedido or modelo)
    except Exception as error:
        # Igual que en el manejador: el tipo y el codigo HTTP, nunca el mensaje.
        return {"error": type(error).__name__, "http": getattr(error, "status_code", None)}

    return {
        "sentimiento": resultado.sentimiento,
        "urgencia": resultado.urgencia,
        "explicacion": resultado.explicacion,
        "senales": resultado.senales,
        "modelo": resultado.motor,
        "milisegundos": round((time.monotonic() - inicio) * 1000),
        "tokens": [resultado.tokens_entrada, resultado.tokens_salida],
    }
