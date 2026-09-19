variable "region" {
  description = "Region de AWS donde vive todo. Irlanda, la misma que TestEnforce."
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Nombre del entorno. Por ahora solo existe dev."
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Prefijo de los nombres de recurso. Evita choques con TestEnforce."
  type        = string
  default     = "workingevents"
}

variable "expected_account_id" {
  description = <<-EOT
    Cuenta donde debe crearse todo. Si las credenciales apuntan a otra,
    Terraform se niega a continuar durante el plan, antes de crear nada.

    Sin valor por defecto a proposito: el repositorio es publico y el numero de
    cuenta no se publica. Va en terraform.tfvars, que esta en .gitignore.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "Un ID de cuenta de AWS son exactamente 12 digitos."
  }
}

variable "email_alertas" {
  description = <<-EOT
    Correo que recibe las alertas de resenya negativa.

    Nunca va escrito en el codigo: es un dato personal. Se pone en
    terraform.tfvars, que esta en .gitignore.

    Se puede dejar VACIO. En ese caso se crea el topic de SNS pero sin ningun
    suscriptor: el resto del flujo funciona y se puede comprobar leyendo la cola
    a mano. Es util para levantar la infraestructura antes de haber decidido la
    direccion.

    IMPORTANTE cuando lo rellenes: tras el apply, AWS envia a esa direccion un
    correo de confirmacion. La suscripcion NO funciona hasta que pulses el
    enlace. Hasta entonces figurara como "PendingConfirmation".
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "email_operaciones" {
  description = <<-EOT
    Correo que recibe las ALARMAS TECNICAS (alarmas.tf): mensajes que fallan,
    errores de la Lambda, mensajes en la DLQ.

    Vacio por defecto: entonces se usa el mismo que email_alertas. Existe para
    poder separar los dos avisos cuando lleguen a personas distintas.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

# ---------------------------------------------------------------------------
# El analisis con IA (Fase 7)
# ---------------------------------------------------------------------------

variable "proveedor_analisis" {
  description = <<-EOT
    Quien analiza el texto de las resenyas:

      lexico      el analizador propio de la Fase 4. Sin IA, sin claves, sin coste.
      anthropic   Claude, con la clave guardada en Secrets Manager.
      openai      GPT, con la clave guardada en Secrets Manager.

    Por defecto "lexico", para que el proyecto funcione recien clonado, antes de
    que nadie haya guardado ninguna clave. Si se elige un proveedor y su clave
    falta o falla, la Lambda vuelve al lexico y salta una alarma.
  EOT
  type        = string
  default     = "lexico"

  validation {
    condition     = var.proveedor_analisis == "lexico" || contains(var.proveedores_llm, var.proveedor_analisis)
    error_message = "Tiene que ser 'lexico' o uno de los proveedores de proveedores_llm."
  }
}

variable "proveedores_llm" {
  description = <<-EOT
    Proveedores para los que se crea un secreto donde guardar la clave. Cada
    secreto cuesta 0,40 $ al mes, exista valor dentro o no. Tener los dos
    permite cambiar de proveedor sin volver a guardar ninguna clave.
  EOT
  type        = set(string)
  default     = ["anthropic", "openai"]

  validation {
    condition     = alltrue([for p in var.proveedores_llm : contains(["anthropic", "openai"], p)])
    error_message = "Solo se admiten 'anthropic' y 'openai'."
  }
}

variable "modelo_anthropic" {
  description = <<-EOT
    Modelo de Claude. Por defecto el recomendado, claude-opus-5 (5 $ / 25 $ por
    millon de tokens de entrada / salida). Mas baratos: claude-sonnet-5 (2 $ / 10 $)
    o claude-haiku-4-5 (1 $ / 5 $). Elegir uno mas barato es una decision de coste
    frente a calidad: la comparadora (src/lambda/comparar.py) ayuda a tomarla.
  EOT
  type        = string
  default     = "claude-opus-5"
}

variable "modelo_openai" {
  description = <<-EOT
    Modelo de OpenAI. Por defecto gpt-5.6-sol (4 $ / 20 $), de gama parecida a
    claude-opus-5, para que la comparacion entre los dos sea justa. Mas baratos:
    gpt-5.6-terra (2 $ / 12 $) o gpt-5.6-luna (0,20 $ / 1,20 $).
  EOT
  type        = string
  default     = "gpt-5.6-sol"
}

variable "log_retention_days" {
  description = "Retencion de los grupos de logs. Sin esto crecen para siempre y se pagan."
  type        = number
  default     = 7
}
