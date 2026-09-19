# ---------------------------------------------------------------------------
# Lambda: el analizador
# ---------------------------------------------------------------------------
# Una Lambda es codigo sin servidor propio. No hay una maquina encendida
# esperando: AWS arranca un contenedor cuando hay trabajo, ejecuta la funcion,
# y lo apaga si deja de haberlo. Se paga por milisegundo de ejecucion.
#
# Seis piezas, en el orden en que dependen unas de otras:
#
#   1. El paquete       el codigo Python, comprimido en un .zip
#   2. El grupo de logs donde escribe la funcion, con fecha de caducidad
#   3. El rol           la identidad con la que actua la funcion
#   4. Los permisos     que puede hacer ese rol, y sobre que
#   5. La funcion       el codigo + el rol + la configuracion
#   6. La conexion      la pieza que vigila la cola y llama a la funcion
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. El paquete
# ---------------------------------------------------------------------------
# Solo la carpeta funcion/: las pruebas no viajan a AWS.
#
# El .zip se genera en infra/build/, que esta en .gitignore: es un producto de
# la compilacion, no codigo fuente.
#
# No hace falta instalar dependencias: el analizador solo usa la biblioteca
# estandar de Python, y boto3 ya viene incluido en el entorno de Lambda.
# ---------------------------------------------------------------------------

data "archive_file" "analizador" {
  type        = "zip"
  source_dir  = "${path.module}/../src/lambda/funcion"
  output_path = "${path.module}/build/analizador.zip"

  # Las caches que Python genera al ejecutar en local no deben viajar: no
  # aportan nada y cambiarian la huella del paquete, forzando un despliegue
  # sin que el codigo haya cambiado.
  excludes = ["__pycache__", "__pycache__/**"]
}

# ---------------------------------------------------------------------------
# 2. El grupo de logs
# ---------------------------------------------------------------------------
# Si no se crea aqui, Lambda lo crea sola la primera vez que escribe... con
# retencion INFINITA. Los logs crecerian para siempre y se pagarian para
# siempre. Creandolo antes se le pone caducidad.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "analizador" {
  name              = "/aws/lambda/${var.project}-analizador"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# 3. El rol: la identidad de la funcion
# ---------------------------------------------------------------------------
# La API usaba tu perfil. La Lambda no tiene perfil: tiene un ROL. Un rol es
# una identidad sin contrasenya que un servicio de AWS puede "ponerse" durante
# un rato, recibiendo credenciales temporales que caducan solas.
#
# La politica de confianza dice QUIEN puede ponerse el rol. Aqui, solo el
# servicio Lambda. Ni tu usuario, ni otro servicio.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "confianza_lambda" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "analizador" {
  name               = "${var.project}-analizador"
  description        = "Identidad de la Lambda que analiza las resenyas"
  assume_role_policy = data.aws_iam_policy_document.confianza_lambda.json
}

# ---------------------------------------------------------------------------
# 4. Los permisos: lo minimo, y solo sobre lo suyo
# ---------------------------------------------------------------------------
# Cada bloque dice: estas ACCIONES, sobre este RECURSO concreto. Nada de "*".
# Si el codigo tuviera un fallo o alguien lo manipulase, lo peor que podria
# hacer es leer ESTA cola y publicar en ESTE topic.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "permisos_analizador" {
  # Recibir mensajes, borrarlos al terminar, y consultar la cola. Son las tres
  # que necesita la conexion del paso 6 para hacer su trabajo.
  statement {
    sid       = "LeerLaCola"
    effect    = "Allow"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.resenyas.arn]
  }

  statement {
    sid       = "PublicarAlertas"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alertas.arn]
  }

  # Escribir en su grupo de logs. El ":*" del final significa "cualquier flujo
  # de logs dentro de este grupo": cada contenedor escribe en su propio flujo.
  statement {
    sid       = "EscribirLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.analizador.arn}:*"]
  }
}

resource "aws_iam_role_policy" "analizador" {
  name   = "analizar-y-avisar"
  role   = aws_iam_role.analizador.id
  policy = data.aws_iam_policy_document.permisos_analizador.json
}

# ---------------------------------------------------------------------------
# 5. La funcion
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "analizador" {
  function_name = "${var.project}-analizador"
  description   = "Analiza el sentimiento de las resenyas y avisa de las negativas"
  role          = aws_iam_role.analizador.arn

  filename = data.archive_file.analizador.output_path

  # La huella del .zip. Si cambias una sola letra del Python, cambia la huella
  # y Terraform sabe que tiene que subir el codigo nuevo. Sin esto, veria el
  # mismo nombre de fichero y no desplegaria nada.
  source_code_hash = data.archive_file.analizador.output_base64sha256

  runtime = "python3.13"

  # "fichero.funcion": en manejador.py, la funcion handler().
  handler = "manejador.handler"

  # arm64 son procesadores Graviton, disenyados por AWS: en torno a un 20% mas
  # baratos por milisegundo que x86. Se puede elegir porque el codigo es Python
  # puro; con librerias compiladas habria que compilarlas para arm.
  architectures = ["arm64"]

  # 128 MB es el minimo, y sobra: analizar un texto corto es trabajo de
  # milisegundos. En Lambda la memoria tambien reparte la CPU, asi que subirla
  # solo tendria sentido si la funcion fuera lenta.
  memory_size = 128

  # 30 segundos. Este valor esta atado al visibility timeout de la cola (180 s
  # en cola.tf): AWS recomienda que la cola sea SEIS veces este numero. Si se
  # sube uno, hay que subir el otro.
  timeout = 30

  environment {
    variables = {
      TOPIC_ARN = aws_sns_topic.alertas.arn
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.analizador.name
  }
}

# ---------------------------------------------------------------------------
# 6. La conexion entre la cola y la funcion (event source mapping)
# ---------------------------------------------------------------------------
# La funcion NO pregunta a la cola. Lo hace esta pieza, que gestiona AWS: un
# vigilante que hace long polling sobre la cola, junta los mensajes en lotes,
# invoca la funcion con cada lote, y borra de la cola los que salieron bien.
#
# Por eso el Python no tiene ni una linea de SQS: recibe los mensajes ya
# leidos, como argumento de handler().
# ---------------------------------------------------------------------------

resource "aws_lambda_event_source_mapping" "cola_a_analizador" {
  event_source_arn = aws_sqs_queue.resenyas.arn
  function_name    = aws_lambda_function.analizador.arn

  # El interruptor general tambien corta aqui. Ver apagado.tf.
  enabled = var.flujo_activo

  # Hasta 10 mensajes por invocacion. Diez resenyas en una llamada cuestan lo
  # mismo en arranque que una.
  batch_size = 10

  # Activa la respuesta por lotes parcial que devuelve handler(). Sin esta
  # linea, AWS ignora la lista de fallidos y reintenta el lote entero.
  function_response_types = ["ReportBatchItemFailures"]

  # -------------------------------------------------------------------------
  # El freno de verdad
  # -------------------------------------------------------------------------
  # Como mucho 2 copias de la funcion a la vez, aunque la cola se llene.
  #
  # Lo habitual seria "reserved concurrency" en la funcion, pero en esta cuenta
  # es IMPOSIBLE: su limite total es de 10 ejecuciones simultaneas (una cuenta
  # normal tiene 1000), y AWS exige dejar siempre 10 sin reservar. Reservar
  # aunque sea 1 dejaria 9, y AWS lo rechaza.
  #
  # Este limite no reserva nada: solo impide que la cola dispare mas de 2 a la
  # vez. El minimo que admite AWS es precisamente 2.
  # -------------------------------------------------------------------------
  scaling_config {
    maximum_concurrency = 2
  }

  # Al crear la conexion, AWS comprueba en ese momento que el rol ya puede leer
  # la cola. Los permisos son un recurso aparte, y sin esta linea Terraform
  # podria crearlos a la vez que la conexion y fallar la comprobacion.
  depends_on = [aws_iam_role_policy.analizador]
}
