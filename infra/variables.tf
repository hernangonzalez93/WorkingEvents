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

variable "umbral_calificacion" {
  description = <<-EOT
    Calificacion maxima que se considera "sospechosa" y se manda a analizar.

    Es el filtro BARATO, el que mira el sobre sin abrir la carta. Se pone en 3 y
    no en 2 a proposito: una resenya de 3 estrellas con un texto furioso deberia
    llegar al analisis de sentimiento, y filtrar por 2 la dejaria fuera para
    siempre. Quien decide de verdad si es negativa es la Lambda, leyendo el
    texto.

    Subirlo a 5 haria pasar TODAS las resenyas por el analisis: mas cobertura,
    mas coste. Bajarlo a 1 ahorraria llamadas y perderia casos.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.umbral_calificacion >= 1 && var.umbral_calificacion <= 5
    error_message = "La calificacion va de 1 a 5."
  }
}

variable "log_retention_days" {
  description = "Retencion de los grupos de logs. Sin esto crecen para siempre y se pagan."
  type        = number
  default     = 7
}
