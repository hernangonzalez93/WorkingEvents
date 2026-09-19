# ---------------------------------------------------------------------------
# Apagado: el freno de mano
# ---------------------------------------------------------------------------
# CONVIENE DECIRLO CLARO, porque aqui no funciona igual que en TestEnforce:
#
# Esta arquitectura NO tiene nada que se pague por horas. No hay contenedores
# encendidos, ni base de datos, ni balanceador. EventBridge, SQS, Lambda y SNS
# se pagan POR USO: si nadie manda resenyas, la factura es exactamente cero sin
# apagar nada. El "apagado nocturno" de TestEnforce existia para dejar de pagar
# unos Fargate que corrian las 24 horas; aqui no hay equivalente.
#
# Entonces, para que un interruptor?
#
# Para el riesgo que SI tiene lo serverless: el BUCLE DESBOCADO. Una Lambda que
# falla y se reintenta, una prueba de carga que alguien deja corriendo, un
# formulario sin limite de peticiones. Cada vuelta invoca la Lambda, llama a
# Comprehend y publica en SNS. Eso si cuesta dinero, y llena tu bandeja de
# entrada de miles de correos. El interruptor corta el flujo en segundos sin
# destruir nada.
#
# Hay tres niveles, de menos a mas drastico:
#
#   Nivel 1  flujo_activo = false  ->  apply. La regla deja de enrutar y la
#            Lambda deja de consumir. Nada se destruye, los mensajes en cola
#            esperan. Se revierte poniendolo a true.
#
#   Nivel 2  El horario nocturno de abajo. Automatico, pero solo cierra la
#            ENTRADA: deshabilita la regla y deja que la Lambda termine lo
#            que ya estuviera en la cola. Asi no queda nada a medias, y los
#            reintentos estan acotados por la cola de mensajes muertos.
#
#   Nivel 3  terraform destroy. Se va todo. En esta arquitectura es barato de
#            rehacer porque no hay datos que perder.
# ---------------------------------------------------------------------------

variable "flujo_activo" {
  description = <<-EOT
    El interruptor general. Con false corta en dos sitios a la vez:
      - la regla de EventBridge deja de enrutar eventos a la cola (eventos.tf)
      - la Lambda deja de consumir la cola (lambda.tf)

    Lo que NO hace: no borra nada, no vacia la cola, no impide que la API
    publique eventos. Los eventos nuevos se publican y se descartan, y lo que
    ya estuviera en la cola espera alli (hasta 4 dias) a que se vuelva a
    encender.
  EOT
  type        = bool
  default     = true
}

variable "apagado_nocturno" {
  description = <<-EOT
    Si crear la cita nocturna que deshabilita la regla sola.

    Por defecto FALSE, al contrario que en TestEnforce. Alli tenia sentido
    siempre, porque olvidarse encendido costaba dinero cada hora. Aqui,
    olvidarse encendido no cuesta nada mientras no haya trafico, y un apagado
    automatico solo conseguiria que manyana no funcione el laboratorio sin que
    recuerdes por que.

    Ponlo a true cuando llegue la Fase 8 y la web y la API vivan en ECS o App
    Runner, que si se pagan por hora. O si vas a dejar corriendo una prueba de
    carga y quieres un limite duro.
  EOT
  type        = bool
  default     = false
}

variable "apagado_cron" {
  description = <<-EOT
    Cuando se apaga, en formato cron de EventBridge. Por defecto a las 22:00
    hora peninsular espanyola.

    El formato lleva seis campos: minuto, hora, dia del mes, mes, dia de la
    semana y anyo. El interrogante significa "cualquiera" en los campos de dia,
    y es obligatorio poner uno de los dos dias como interrogante.
  EOT
  type        = string
  default     = "cron(0 22 * * ? *)"
}

variable "apagado_zona_horaria" {
  description = "Zona horaria del apagado. Con esto el horario de verano se ajusta solo."
  type        = string
  default     = "Europe/Madrid"
}

# ---------------------------------------------------------------------------
# UNA ADVERTENCIA sobre mezclar el nivel 1 y el nivel 2
# ---------------------------------------------------------------------------
# Si el horario nocturno deshabilita la regla y manyana lanzas `terraform
# apply`, Terraform vera que el codigo dice ENABLED y la realidad dice DISABLED,
# y la volvera a habilitar. Eso es "deriva de configuracion" (drift), y en este
# caso es el comportamiento deseado: aplicar significa "quiero que esto
# funcione". Pero conviene saberlo para no pensar que el apagado esta roto.
#
# Para apagar de forma que sobreviva a un apply, usa el nivel 1: flujo_activo.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# El permiso para apagar, acotado a lo minimo
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "confianza_planificador" {
  count = var.apagado_nocturno ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Sin esta condicion, cualquier planificador de la cuenta podria asumir el
    # rol. Con ella, solo los de esta cuenta.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.actual.account_id]
    }
  }
}

resource "aws_iam_role" "planificador" {
  count = var.apagado_nocturno ? 1 : 0

  name               = "${var.project}-apagado"
  description        = "Permite al planificador deshabilitar la regla de resenyas"
  assume_role_policy = data.aws_iam_policy_document.confianza_planificador[0].json
}

data "aws_iam_policy_document" "apagar" {
  count = var.apagado_nocturno ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["events:DisableRule"]

    # ESA regla, y ninguna otra. Un rol que solo sabe hacer una cosa sobre un
    # sitio concreto es un rol que no puede sorprenderte.
    resources = [aws_cloudwatch_event_rule.resenyas_sospechosas.arn]
  }
}

resource "aws_iam_role_policy" "apagar" {
  count = var.apagado_nocturno ? 1 : 0

  name   = "apagar-flujo"
  role   = aws_iam_role.planificador[0].id
  policy = data.aws_iam_policy_document.apagar[0].json
}

# ---------------------------------------------------------------------------
# La cita nocturna
# ---------------------------------------------------------------------------

resource "aws_scheduler_schedule" "apagado" {
  count = var.apagado_nocturno ? 1 : 0

  name                         = "${var.project}-apagar-flujo"
  description                  = "Deshabilita la regla de resenyas cada noche"
  schedule_expression          = var.apagado_cron
  schedule_expression_timezone = var.apagado_zona_horaria

  flexible_time_window {
    mode = "OFF"
  }

  target {
    # Un "destino universal": el planificador llama directamente a la API de
    # AWS, sin una funcion Lambda intermedia que mantener.
    arn      = "arn:aws:scheduler:::aws-sdk:eventbridge:disableRule"
    role_arn = aws_iam_role.planificador[0].arn

    input = jsonencode({
      Name         = aws_cloudwatch_event_rule.resenyas_sospechosas.name
      EventBusName = aws_cloudwatch_event_bus.principal.name
    })
  }
}
