# ---------------------------------------------------------------------------
# Alarmas: enterarse de que algo falla sin tener que ir a mirar
# ---------------------------------------------------------------------------
# Tres piezas de CloudWatch, que conviene no confundir:
#
#   LOG      Un texto que escribe el codigo: "Fallo al procesar el mensaje X".
#            Cuenta QUE paso, con detalle. Pero nadie lo lee si no va a buscarlo.
#
#   METRICA  Un numero en el tiempo: "mensajes en la DLQ, minuto a minuto".
#            No cuenta el detalle, pero se puede vigilar automaticamente.
#
#   ALARMA   Un vigilante sobre una metrica: "si pasa de 0, avisa". Tiene tres
#            estados: OK, ALARM (se cumplio la condicion) e INSUFFICIENT_DATA
#            (no hay datos para decidir). Avisa al CAMBIAR de estado, no en cada
#            comprobacion: un correo al saltar y otro al volver a OK.
#
# Hay cuatro alarmas, cada una para un tipo de fallo que las otras no ven:
#
#   1. Mensajes que fallan  (metrica sacada de los LOGS)   -> aviso inmediato
#   2. Errores de la Lambda (metrica de AWS/Lambda)        -> la funcion entera revienta
#   3. Mensajes en la DLQ   (metrica de AWS/SQS)           -> la ultima red: hay que actuar
#   4. Analisis degradado   (metrica sacada de los LOGS)   -> la IA fallo y se uso el lexico
#
# Coste: CloudWatch regala cada mes 10 alarmas y 10 metricas personalizadas.
# Aqui hay 4 alarmas y 2 metricas personalizadas, asi que el coste es cero.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# El destino de los avisos tecnicos: un topic APARTE
# ---------------------------------------------------------------------------
# No se reutiliza el de las resenyas negativas a proposito. Son dos avisos con
# significados y destinatarios distintos:
#
#   alertas-resenyas     "un cliente esta enfadado"   -> atencion al cliente
#   alarmas-operacion    "el sistema esta roto"       -> quien mantiene el sistema
#
# En este laboratorio van al mismo correo, pero separarlos cuesta una linea y
# permite mandarlos a sitios distintos cambiando solo email_operaciones.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "operaciones" {
  name         = "${var.project}-alarmas-operacion"
  display_name = "Alarmas WorkingEvents"
}

locals {
  # Si no se indica un correo propio para las alarmas, van al de las alertas.
  email_operaciones = var.email_operaciones != "" ? var.email_operaciones : var.email_alertas
}

resource "aws_sns_topic_subscription" "operaciones_correo" {
  # Igual que en notificaciones.tf: sin correo, no hay suscripcion. Y como es
  # una suscripcion NUEVA, llegara otro correo de confirmacion que hay que
  # aceptar; hasta entonces las alarmas saltan, pero su aviso no llega.
  count = nonsensitive(local.email_operaciones) != "" ? 1 : 0

  topic_arn = aws_sns_topic.operaciones.arn
  protocol  = "email"
  endpoint  = local.email_operaciones

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# 1. Mensajes que fallan: una metrica fabricada a partir de los logs
# ---------------------------------------------------------------------------
# Cuando falla UN mensaje de un lote, handler() captura la excepcion, escribe
# "Fallo al procesar el mensaje <id>" y sigue con los demas. Para Lambda, esa
# invocacion termino BIEN: la metrica Errors no se entera (alarma 2).
#
# Un filtro de metricas lee los logs segun llegan y, por cada linea que
# contiene ese texto, suma 1 a una metrica propia. Asi un texto se convierte en
# un numero que se puede vigilar.
#
# OJO: el texto tiene que coincidir EXACTAMENTE con el de manejador.py. Si
# alguien lo cambia alli, este filtro deja de contar sin dar ningun error.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "mensajes_fallidos" {
  name           = "${var.project}-mensajes-fallidos"
  log_group_name = aws_cloudwatch_log_group.analizador.name

  # Las comillas hacen que se busque la frase entera, y no cada palabra suelta.
  pattern = "\"Fallo al procesar el mensaje\""

  metric_transformation {
    name      = "MensajesFallidos"
    namespace = "WorkingEvents"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "mensajes_fallidos" {
  alarm_name        = "${var.project}-mensajes-fallidos"
  alarm_description = "Un mensaje de la cola ha fallado al procesarse. Se reintentara, y al tercer fallo ira a la DLQ. Buscar 'Fallo al procesar' en los logs de la Lambda."

  namespace   = "WorkingEvents"
  metric_name = "MensajesFallidos"
  statistic   = "Sum"

  # "Si en un minuto hay al menos un fallo, alarma."
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  # Esta metrica solo tiene datos cuando algo falla. El resto del tiempo NO HAY
  # datos, y eso es la situacion normal: se trata como "todo bien". Sin esta
  # linea, la alarma pasaria casi siempre a INSUFFICIENT_DATA.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.operaciones.arn]
  ok_actions    = [aws_sns_topic.operaciones.arn]
}

# ---------------------------------------------------------------------------
# 2. Errores de la Lambda: la funcion entera revienta
# ---------------------------------------------------------------------------
# Cubre justo lo que la alarma 1 no ve. Si la funcion falla ANTES de llegar al
# bucle de mensajes (le falta TOPIC_ARN, un error al importar, el evento no
# tiene la forma esperada...), no se escribe "Fallo al procesar" y la alarma 1
# no se entera. Pero Lambda si lo cuenta en Errors.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "errores_lambda" {
  alarm_name        = "${var.project}-errores-lambda"
  alarm_description = "La Lambda analizadora ha fallado entera, no un mensaje suelto. Revisar sus logs: el error suele estar al principio de la invocacion."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions = {
    FunctionName = aws_lambda_function.analizador.function_name
  }
  statistic = "Sum"

  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.operaciones.arn]
  ok_actions    = [aws_sns_topic.operaciones.arn]
}

# ---------------------------------------------------------------------------
# 3. Mensajes en la DLQ: la ultima red
# ---------------------------------------------------------------------------
# Si un mensaje llega aqui es que fallo tres veces seguidas. Ya no se va a
# reintentar solo: necesita que una persona lo mire.
#
# A diferencia de las otras dos, esta alarma NO se apaga sola al cabo de un
# minuto. Sigue en ALARM mientras haya mensajes en la DLQ, porque la situacion
# sigue sin resolver. Vuelve a OK cuando alguien los revisa y los borra (o los
# devuelve a la cola principal, si el fallo era pasajero y ya esta arreglado).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq_con_mensajes" {
  alarm_name        = "${var.project}-dlq-con-mensajes"
  alarm_description = "Hay resenyas en la cola de mensajes muertos: fallaron tres veces y nadie las ha analizado. Revisar el mensaje, arreglar la causa, y despues borrarlo o devolverlo a la cola."

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions = {
    QueueName = aws_sqs_queue.muertos.name
  }

  # El MAXIMO del minuto, y no la media: con que haya uno en algun momento, basta.
  statistic = "Maximum"

  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  # SQS deja de publicar metricas de una cola que lleva horas sin actividad. Una
  # DLQ vacia e inactiva es la situacion normal, asi que la falta de datos se
  # trata como "todo bien".
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.operaciones.arn]
  ok_actions    = [aws_sns_topic.operaciones.arn]
}

# ---------------------------------------------------------------------------
# 4. Analisis degradado: la IA fallo y se analizo con el lexico (Fase 7)
# ---------------------------------------------------------------------------
# Si el proveedor de IA falla (caido, clave caducada, secreto vacio, modelo que
# no existe...), la Lambda no deja de analizar: vuelve al lexico. Es mejor que
# no analizar, pero PEOR que lo que se configuro, y alguien tiene que saberlo.
#
# Es el mismo patron que la alarma 1: el manejador escribe "Analisis degradado"
# y un filtro lo convierte en metrica. El texto tiene que coincidir EXACTAMENTE
# con el de manejador.py.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "analisis_degradado" {
  name           = "${var.project}-analisis-degradado"
  log_group_name = aws_cloudwatch_log_group.analizador.name
  pattern        = "\"Analisis degradado\""

  metric_transformation {
    name      = "AnalisisDegradado"
    namespace = "WorkingEvents"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "analisis_degradado" {
  alarm_name        = "${var.project}-analisis-degradado"
  alarm_description = "El proveedor de IA ha fallado y las resenyas se estan analizando con el lexico. Buscar 'Analisis degradado' en los logs: dice el tipo de error (clave, modelo, secreto vacio...)."

  namespace   = "WorkingEvents"
  metric_name = "AnalisisDegradado"
  statistic   = "Sum"

  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.operaciones.arn]
  ok_actions    = [aws_sns_topic.operaciones.arn]
}

