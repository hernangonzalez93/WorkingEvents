# ---------------------------------------------------------------------------
# La comparadora: el mismo codigo, otra puerta de entrada
# ---------------------------------------------------------------------------
# Una segunda Lambda que analiza unas resenyas de prueba con los tres motores
# (lexico, Anthropic y OpenAI) y devuelve los resultados lado a lado. NO lee la
# cola ni envia correos: se invoca a mano, con src/lambda/comparar.py.
#
# Comparte con la analizadora el paquete de codigo y la capa. Cambia la puerta
# de entrada, `handler`: comparador.handler en lugar de manejador.handler. Un
# mismo .zip puede tener tantas puertas como funciones lo usen.
#
# Y tiene un rol propio, porque necesita cosas distintas: puede leer las DOS
# claves (compara los dos proveedores), pero no puede tocar la cola ni SNS.
#
# Por que en AWS y no en tu equipo: asi las claves no salen nunca de AWS, y se
# prueban exactamente el mismo codigo y las mismas librerias que usara la
# analizadora.
#
# Coste en reposo: cero. Solo se paga cuando se invoca.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "comparador" {
  name              = "/aws/lambda/${var.project}-comparador"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "comparador" {
  name               = "${var.project}-comparador"
  description        = "Identidad de la Lambda que compara los motores de analisis"
  assume_role_policy = data.aws_iam_policy_document.confianza_lambda.json
}

data "aws_iam_policy_document" "permisos_comparador" {
  statement {
    sid       = "LeerLasClaves"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for s in aws_secretsmanager_secret.clave_llm : s.arn]
  }

  statement {
    sid       = "EscribirLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.comparador.arn}:*"]
  }
}

resource "aws_iam_role_policy" "comparador" {
  name   = "leer-claves"
  role   = aws_iam_role.comparador.id
  policy = data.aws_iam_policy_document.permisos_comparador.json
}

resource "aws_lambda_function" "comparador" {
  function_name = "${var.project}-comparador"
  description   = "Compara el lexico, Anthropic y OpenAI sobre las mismas resenyas. No envia correos."
  role          = aws_iam_role.comparador.arn

  # El MISMO paquete y la MISMA capa que la analizadora.
  filename         = data.archive_file.analizador.output_path
  source_code_hash = data.archive_file.analizador.output_base64sha256
  layers           = [aws_lambda_layer_version.dependencias.arn]

  # La otra puerta de entrada.
  handler = "comparador.handler"

  runtime       = "python3.13"
  architectures = ["arm64"]
  memory_size   = 256

  # 10 resenyas x 2 proveedores x hasta 20 s cada una, en el peor caso. Aqui no
  # hay cola ni visibility timeout con el que cuadrar: solo quien espera la
  # respuesta (comparar.py espera hasta 300 s).
  timeout = 300

  environment {
    variables = {
      SECRETO_ANTHROPIC = try(aws_secretsmanager_secret.clave_llm["anthropic"].name, "")
      SECRETO_OPENAI    = try(aws_secretsmanager_secret.clave_llm["openai"].name, "")
      MODELO_ANTHROPIC  = var.modelo_anthropic
      MODELO_OPENAI     = var.modelo_openai
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.comparador.name
  }
}
