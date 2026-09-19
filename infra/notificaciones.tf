# ---------------------------------------------------------------------------
# SNS: el altavoz
# ---------------------------------------------------------------------------
# Un "topic" de SNS es un tablon de anuncios. Quien tiene algo que decir lo
# publica en el tablon; quien quiere enterarse se suscribe. Ninguno de los dos
# conoce al otro.
#
# Por que no enviar el correo directamente desde la Lambda: porque entonces el
# codigo tendria que saber a quien avisar. Con SNS, la Lambda solo dice "esta
# resenya es negativa" y manyana puedes anyadir un SMS, un Slack o una segunda
# Lambda que abra un ticket, sin tocar una linea de Python.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alertas" {
  name         = "${var.project}-alertas-resenyas"
  display_name = "Alertas resenyas"
}

# ---------------------------------------------------------------------------
# La suscripcion por correo
# ---------------------------------------------------------------------------
# OJO: esto NO activa el correo por si solo. Al aplicarlo, AWS envia un mensaje
# de confirmacion a la direccion y la suscripcion queda en "PendingConfirmation"
# hasta que pulses el enlace. Es a proposito: impide que cualquiera suscriba tu
# correo a un topic ajeno.
#
# Terraform no puede esperar a ese clic, asi que despues del apply siempre vera
# la suscripcion como creada aunque siga sin confirmar. Se comprueba con:
#   aws sns list-subscriptions-by-topic --topic-arn <arn>
# ---------------------------------------------------------------------------

resource "aws_sns_topic_subscription" "correo" {
  # Si no hay correo configurado, no se crea ninguna suscripcion y el topic se
  # queda sin oyentes. El resto del flujo sigue funcionando: se puede comprobar
  # leyendo la cola a mano o mirando las metricas del topic.
  count = nonsensitive(var.email_alertas) != "" ? 1 : 0

  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "email"
  endpoint  = var.email_alertas

  # Sin esto, cada cambio del correo intentaria borrar la suscripcion anterior,
  # y una suscripcion sin confirmar no se puede borrar limpiamente.
  lifecycle {
    create_before_destroy = true
  }
}
