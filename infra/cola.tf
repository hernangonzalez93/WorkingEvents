# ---------------------------------------------------------------------------
# SQS: la bandeja de entrada
# ---------------------------------------------------------------------------
# Una cola guarda mensajes hasta que alguien los recoge. Aqui hay dos.
#
# Por que hace falta una cola si EventBridge ya podria llamar a la Lambda
# directamente:
#
#   1. RESISTENCIA. Si la Lambda esta caida o falla, el mensaje sigue en la cola
#      y se reintenta. Sin cola, se pierde.
#   2. AMORTIGUACION. Si entran 10.000 resenyas de golpe, la cola las aguanta y
#      la Lambda las consume a su ritmo en vez de reventar.
#   3. LOTES. La Lambda puede recoger varios mensajes de una sola invocacion.
#
# Un mensaje en SQS no se borra al leerlo: se vuelve INVISIBLE durante un rato
# (el "visibility timeout"). Si quien lo leyo confirma que lo proceso, se borra.
# Si no confirma —porque fallo o murio—, reaparece y otro lo intenta. Es lo que
# garantiza que nada se pierda por el camino.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# La cola de mensajes muertos (DLQ)
# ---------------------------------------------------------------------------
# El hospital de los mensajes que no hay manera de procesar. Sin ella, un
# mensaje que siempre falla —un JSON corrupto, por ejemplo— reaparece una y otra
# vez para siempre: cada reintento invoca la Lambda, y cada invocacion llama a
# Comprehend. Un bucle asi cuesta dinero de verdad.
#
# Se declara ANTES que la principal porque la principal la necesita para
# apuntar a ella.
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "muertos" {
  name = "${var.project}-resenyas-dlq"

  # 14 dias, el maximo. Aqui llega lo que hay que investigar a mano, y conviene
  # tener margen para verlo sin prisa.
  message_retention_seconds = 1209600
}

# ---------------------------------------------------------------------------
# La cola principal
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "resenyas" {
  name = "${var.project}-resenyas"

  # Cuanto tiempo queda invisible un mensaje mientras se procesa. La regla que
  # recomienda AWS es SEIS VECES el timeout de la Lambda. Si fuera menor, el
  # mensaje reaparaceria mientras todavia se esta procesando y una segunda
  # invocacion haria el mismo trabajo: correo duplicado y coste duplicado.
  # La Lambda tendra 30 s de timeout, asi que 180 s.
  visibility_timeout_seconds = 180

  # 4 dias. Si nadie lo recoge en ese plazo, algo esta roto de todas formas.
  message_retention_seconds = 345600

  # Espera hasta 20 s a que haya mensajes antes de responder "no hay nada"
  # ("long polling"). Sin esto la Lambda pregunta constantemente y cada pregunta
  # es una peticion facturable. Con esto, menos peticiones y menos latencia.
  receive_wait_time_seconds = 20

  # La red de seguridad: tras 3 intentos fallidos, el mensaje se aparta.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.muertos.arn
    maxReceiveCount     = 3
  })
}

# ---------------------------------------------------------------------------
# El permiso para que EventBridge deposite mensajes
# ---------------------------------------------------------------------------
# Una cola de SQS, por defecto, solo acepta mensajes de quien sea su duenyo.
# EventBridge es otro servicio distinto: sin este permiso explicito, la regla se
# dispararia, intentaria entregar, fallaria en silencio, y la cola se quedaria
# vacia sin ningun error visible. Es uno de los fallos mas comunes al montar
# esta arquitectura por primera vez.
#
# La condicion SourceArn es lo que lo mantiene seguro: no abre la cola a "todo
# EventBridge", solo a ESTA regla concreta.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cola_acepta_eventbridge" {
  statement {
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sqs_queue.resenyas.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.resenyas_sospechosas.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "resenyas" {
  queue_url = aws_sqs_queue.resenyas.id
  policy    = data.aws_iam_policy_document.cola_acepta_eventbridge.json
}
