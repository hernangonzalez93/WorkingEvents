"""
Simula en local un ciclo completo del event source mapping (el "portero").

    python -B src/lambda/simulacion/simular_esm.py

El paso 4 ejecuta el codigo REAL de la Lambda (manejador.handler). Lo demas
(el portero y SNS) esta imitado con print, para ver que entra y que sale en
cada paso sin desplegar nada. Lo explica docs/EVENT-SOURCE-MAPPING.md.
"""

import json
import logging
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)                                    # el boto3 falso
sys.path.insert(0, os.path.join(AQUI, "..", "funcion"))     # el codigo real
os.environ["TOPIC_ARN"] = "arn:aws:sns:eu-west-1:000000000000:workingevents-alertas-resenyas"


class _Corto(logging.Handler):
    def emit(self, registro):
        print("      [log]", registro.getMessage())


logging.getLogger().addHandler(_Corto())

import manejador  # noqa: E402  (el codigo REAL de la Lambda)

COLA = "arn:aws:sqs:eu-west-1:000000000000:workingevents-resenyas"


def sobre(id_, calificacion, texto):
    return json.dumps({
        "version": "0", "id": f"evt-{id_}", "detail-type": "ResenyaEnviada",
        "source": "workingevents.api", "time": "2026-09-19T12:00:00Z",
        "detail": {"id": f"rev-{id_}", "comentario": texto,
                   "calificacion": calificacion, "email": "c@ejemplo.com"},
    })


def registro(msg_id, body):
    # La forma en que el event source mapping entrega cada mensaje (los
    # mensajes reales traen algunos atributos mas, que aqui no se usan).
    return {"messageId": msg_id, "receiptHandle": f"AQEB...{msg_id}", "body": body,
            "attributes": {"ApproximateReceiveCount": "1"},
            "eventSource": "aws:sqs", "eventSourceARN": COLA, "awsRegion": "eu-west-1"}


en_la_cola = [
    registro("msg-A", sobre("A", 2, "Llego roto y nadie contesta.")),
    registro("msg-B", sobre("B", 3, "Cumple su funcion.")),
    registro("msg-C", '{"esto": "no es una resenya"}'),
]

print("PASO 1-2 | El portero pide mensajes a SQS y recibe 3. SQS los vuelve INVISIBLES.")
for r in en_la_cola:
    print(f"          {r['messageId']}")

print("\nPASO 3   | El portero invoca la Lambda con un unico `event` que lleva los 3 dentro.")

print("\nPASO 4   | La Lambda ejecuta handler(event):")
respuesta = manejador.handler({"Records": en_la_cola}, None)

print("\nPASO 5   | La Lambda DEVUELVE al portero:")
print("          " + json.dumps(respuesta))

fallidos = {f["itemIdentifier"] for f in respuesta["batchItemFailures"]}
print("\nPASO 6   | El portero lee esa respuesta y actua sobre SQS:")
for r in en_la_cola:
    if r["messageId"] in fallidos:
        print(f"          {r['messageId']}: NO lo borra -> reaparecera al acabar el "
              "visibility timeout (al tercer fallo, SQS lo manda a la DLQ)")
    else:
        print(f"          {r['messageId']}: DeleteMessage -> desaparece de la cola")
