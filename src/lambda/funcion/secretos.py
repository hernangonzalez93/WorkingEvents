"""
Lee las claves de API de Secrets Manager.

La clave nunca esta en el codigo, ni en Terraform, ni en las variables de
entorno de la Lambda: solo el NOMBRE del secreto. El valor se pide en tiempo de
ejecucion, con el permiso del rol de la funcion.

Se guarda en memoria 5 minutos. Sin esa cache, cada resenya haria una llamada a
Secrets Manager, y cada 10.000 llamadas se pagan. Con ella, si cambias la clave,
la Lambda la vera como mucho 5 minutos despues.
"""

import time

import boto3

VIGENCIA_SEGUNDOS = 300

_cliente = boto3.client("secretsmanager")
_cache: dict[str, tuple[str, float]] = {}


def leer(secreto_id: str) -> str:
    guardado = _cache.get(secreto_id)
    if guardado and time.monotonic() - guardado[1] < VIGENCIA_SEGUNDOS:
        return guardado[0]

    # Si el secreto existe pero nadie le ha puesto valor todavia, esto lanza
    # ResourceNotFoundException. El manejador lo trata como cualquier otro fallo
    # del analisis con IA: pasa al lexico y lo deja escrito en el log.
    valor = _cliente.get_secret_value(SecretId=secreto_id)["SecretString"].strip()
    _cache[secreto_id] = (valor, time.monotonic())
    return valor
