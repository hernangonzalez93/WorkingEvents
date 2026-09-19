# ---------------------------------------------------------------------------
# EventBridge: la centralita
# ---------------------------------------------------------------------------
# Llegan eventos, EventBridge mira el "sobre" y decide a que destino van segun
# reglas que tu escribes. No abre la carta ni guarda nada: reparte y olvida. Un
# evento que no encaja con ninguna regla se descarta sin error.
#
# Un evento es una NOTICIA en pasado ("se envio una resenya"), no una orden
# ("manda un correo"). Esa distincion es la que permite anyadir destinos nuevos
# sin tocar a quien lo publica: el productor no sabe ni le importa quien
# escucha.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# El bus propio
# ---------------------------------------------------------------------------
# Toda cuenta de AWS trae un bus "default" donde caen tambien los eventos de los
# propios servicios de AWS (arranques de EC2, cambios de estado...). Se crea uno
# propio para que aqui solo viva lo de este proyecto: los patrones son mas
# simples, los permisos mas acotados y las metricas no se mezclan.
#
# Un bus personalizado no cuesta nada. Se paga por evento publicado: 1 $ por
# millon. Este laboratorio no llegara ni a un centimo.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_bus" "principal" {
  name = "${var.project}-bus"
}

# ---------------------------------------------------------------------------
# La regla
# ---------------------------------------------------------------------------
# El "event pattern" es una plantilla: si el evento la encaja, la regla se
# dispara. La comparacion es por ESTRUCTURA, no por texto. Cada clave del patron
# tiene que existir en el evento, y su valor estar entre los listados.
#
# HASTA LA FASE 6 tambien filtraba por calificacion (<= 3): solo las resenyas
# "sospechosas" llegaban a la cola. Desde la Fase 7 pasan TODAS, y es la Lambda
# quien decide leyendo el texto. El motivo: una resenya de 5 estrellas puede ser
# una queja ("Todo perfecto, nunca mas compro aqui") o esconder algo urgente
# ("me encanta, pero me habeis cobrado dos veces"), y el filtro por nota la
# descartaba sin que nadie la leyera.
#
# El precio: una invocacion de la Lambda, y una llamada a la IA si se usa, por
# CADA resenya, no solo por las malas.
#
# La regla sigue filtrando, pero solo por el sobre: que el evento venga de la
# API y sea una resenya. Sin esto, cualquier otro evento publicado en el bus
# acabaria tambien en la cola.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "resenyas" {
  name           = "${var.project}-resenyas"
  description    = "Envia a la cola todas las resenyas que publica la API"
  event_bus_name = aws_cloudwatch_event_bus.principal.name

  # El interruptor general. Ver apagado.tf.
  state = var.flujo_activo ? "ENABLED" : "DISABLED"

  event_pattern = jsonencode({
    source        = ["${var.project}.api"]
    "detail-type" = ["ResenyaEnviada"]
  })
}

# La regla se llamaba "resenyas_sospechosas" y ya no filtra sospechosas. Este
# bloque le dice a Terraform que es el MISMO recurso con otro nombre en el
# codigo, y no uno viejo que borrar y otro nuevo que crear. Como tambien cambia
# su nombre en AWS, AWS la sustituira igualmente, pero el plan lo muestra como
# lo que es: un cambio de nombre.
moved {
  from = aws_cloudwatch_event_rule.resenyas_sospechosas
  to   = aws_cloudwatch_event_rule.resenyas
}

# ---------------------------------------------------------------------------
# El destino
# ---------------------------------------------------------------------------
# Una regla sin destino no hace nada: encaja el evento y lo tira. El destino es
# la cola.
#
# Se envia el evento ENTERO (no se usa input_transformer) para que la Lambda
# reciba tambien los metadatos que anyade EventBridge: el identificador del
# evento y su marca de tiempo. Son utiles para depurar y para descartar
# duplicados.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_target" "a_la_cola" {
  rule           = aws_cloudwatch_event_rule.resenyas.name
  event_bus_name = aws_cloudwatch_event_bus.principal.name
  target_id      = "cola-de-resenyas"
  arn            = aws_sqs_queue.resenyas.arn
}
