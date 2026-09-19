"""
Todo lo que hay entre el mensaje de la cola y la decision de avisar.

Sin boto3 a proposito: nada de lo que hay aqui habla con AWS, asi que se puede
probar en local sin credenciales ni conexion. La unica pieza que toca AWS es
manejador.py, y es deliberadamente pequenya.
"""

import json
from dataclasses import dataclass

from analizador import Resultado


@dataclass(frozen=True)
class Resenya:
    id: str
    comentario: str
    calificacion: int
    email: str
    event_id: str  # El numero de seguimiento de EventBridge (va en el sobre)
    recibida: str  # Cuando la recibio EventBridge, en UTC


def extraer_resenya(registro: dict) -> Resenya:
    """Abre las tres capas de la matrioska, en orden.

      registro["body"]  -> TEXTO, porque SQS solo guarda texto
      json.loads(...)   -> el SOBRE de EventBridge (id, time, detail...)
      sobre["detail"]   -> la CARTA: la resenya que publico la API

    Si falta cualquier campo, lanza una excepcion a proposito. Un mensaje asi no
    se arregla reintentando: tras tres intentos acabara en la cola de mensajes
    muertos, que es exactamente donde tiene que ir para mirarlo a mano.
    """
    sobre = json.loads(registro["body"])
    carta = sobre["detail"]

    return Resenya(
        id=carta["id"],
        comentario=carta["comentario"],
        calificacion=int(carta["calificacion"]),
        email=carta["email"],
        event_id=sobre["id"],
        recibida=sobre["time"],
    )


def requiere_alerta(resenya: Resenya, resultado: Resultado) -> tuple[bool, str]:
    """Decide si se avisa, y por que. El motivo va al log y al correo."""
    if resultado.sentimiento == "NEGATIVO":
        return True, "el texto es negativo"

    # Una estrella casi nunca es un elogio. Si el texto no contiene nada que el
    # lexico reconozca ("Llego el martes."), la nota por si sola basta.
    if resenya.calificacion <= 1:
        return True, "calificación mínima (1 estrella)"

    return False, "ni el texto es negativo ni la calificación es la mínima"


def componer_mensaje(resenya: Resenya, resultado: Resultado, motivo: str) -> tuple[str, str]:
    """Devuelve (asunto, cuerpo) del correo."""
    # SNS exige que el asunto tenga menos de 100 caracteres y ningun salto de
    # linea. Ademas va sin tildes ni enyes, para no depender de como lo muestre
    # cada cliente de correo. El cuerpo no tiene esas limitaciones.
    asunto = f"ALERTA resenya {resenya.calificacion}/5 - {resenya.id}"[:99]

    senales = ", ".join(resultado.senales) or "ninguna palabra reconocida"

    cuerpo = f"""Se ha recibido una reseña que requiere atención inmediata.

Motivo:        {motivo}
Calificación:  {resenya.calificacion}/5
Sentimiento:   {resultado.sentimiento} (puntuación {resultado.puntuacion:+g})
Señales:       {senales}

Comentario del cliente:
  "{resenya.comentario}"

Contactar a:   {resenya.email}

--
Reseña:        {resenya.id}
Evento:        {resenya.event_id}
Recibida:      {resenya.recibida} (UTC)
"""
    return asunto, cuerpo
