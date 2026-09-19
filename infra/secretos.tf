# ---------------------------------------------------------------------------
# Secrets Manager: la caja fuerte de las claves de API
# ---------------------------------------------------------------------------
# Terraform crea el SECRETO (la caja), pero NUNCA su valor (lo que va dentro).
#
# Si la clave pasara por Terraform, quedaria escrita en terraform.tfvars y, en
# texto plano, en el estado guardado en S3: ya se vio en la Fase 2 que
# `sensitive` oculta en pantalla, pero no cifra. Por eso el valor se pone a mano,
# una sola vez, con el comando de docs/IA.md, y nunca toca un fichero del
# proyecto.
#
# Coste: 0,40 $ al mes por secreto, mas 0,05 $ por cada 10.000 lecturas. La
# Lambda guarda la clave 5 minutos en memoria, asi que las lecturas son pocas.
#
# Alternativa gratuita: SSM Parameter Store con parametros SecureString. Tambien
# cifra, pero no ofrece rotacion automatica, ni acceso desde otras cuentas, ni
# versiones etiquetadas. Aqui se usa Secrets Manager porque aprenderlo era parte
# del objetivo de la fase.
# ---------------------------------------------------------------------------

locals {
  # El modelo que corresponde a cada proveedor, para no repetir la eleccion en
  # cada sitio que la necesita.
  modelos = {
    anthropic = var.modelo_anthropic
    openai    = var.modelo_openai
  }
}

resource "aws_secretsmanager_secret" "clave_llm" {
  # for_each crea UN secreto por cada proveedor de la lista. En el codigo se
  # distinguen por su clave: aws_secretsmanager_secret.clave_llm["anthropic"].
  for_each = var.proveedores_llm

  name        = "${var.project}/${each.key}-api-key"
  description = "Clave de la API de ${each.key} para el analisis de resenyas. El valor se pone a mano, nunca con Terraform."

  # Por defecto, un secreto borrado se queda 7-30 dias "pendiente de borrado", y
  # mientras tanto su NOMBRE sigue ocupado: un destroy seguido de un apply
  # fallaria al intentar crearlo otra vez. En un laboratorio que se monta y se
  # desmonta, se borra al momento. En produccion convendria dejar ese margen,
  # porque es lo que permite recuperar una clave borrada por error.
  recovery_window_in_days = 0
}
