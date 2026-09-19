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
# La regla de filtrado
# ---------------------------------------------------------------------------
# El "event pattern" es una plantilla: si el evento la encaja, la regla se
# dispara. La comparacion es por ESTRUCTURA, no por texto. Cada clave del patron
# tiene que existir en el evento, y su valor estar entre los listados.
#
# Este patron dice: eventos de nuestra API, del tipo ResenyaEnviada, cuya
# calificacion sea menor o igual al umbral. Una resenya de 5 estrellas no encaja
# y EventBridge la descarta: nunca llega a la cola y nunca se analiza.
#
# Nota sobre `numeric`: sin el, ["1","2","3"] compararia TEXTO y fallaria con
# cualquier numero fuera de la lista. Con `numeric` compara de verdad como
# numero, asi que cambiar el umbral no obliga a reescribir el patron.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "resenyas_sospechosas" {
  name           = "${var.project}-resenyas-sospechosas"
  description    = "Envia a la cola las resenyas con calificacion <= ${var.umbral_calificacion}"
  event_bus_name = aws_cloudwatch_event_bus.principal.name

  # El interruptor general. Ver apagado.tf.
  state = var.flujo_activo ? "ENABLED" : "DISABLED"

  event_pattern = jsonencode({
    source        = ["${var.project}.api"]
    "detail-type" = ["ResenyaEnviada"]
    detail = {
      calificacion = [{ numeric = ["<=", var.umbral_calificacion] }]
    }
  })
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
  rule           = aws_cloudwatch_event_rule.resenyas_sospechosas.name
  event_bus_name = aws_cloudwatch_event_bus.principal.name
  target_id      = "cola-de-resenyas"
  arn            = aws_sqs_queue.resenyas.arn
}
