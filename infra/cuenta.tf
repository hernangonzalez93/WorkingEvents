# ---------------------------------------------------------------------------
# Guardia de cuenta
# ---------------------------------------------------------------------------
# Comprueba, durante el PLAN y antes de crear nada, que las credenciales
# apuntan a la cuenta esperada.
#
# Existe porque el fallo contrario ya ocurrio en TestEnforce: un plan guardado
# con un perfil se aplico con otro y los recursos aparecieron en la cuenta
# equivocada. Abrir una terminal nueva pierde AWS_PROFILE y te deja usando el
# perfil `default` sin avisar.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "actual" {}

resource "terraform_data" "guardia_de_cuenta" {
  input = data.aws_caller_identity.actual.account_id

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.actual.account_id == var.expected_account_id
      error_message = <<-EOT
        Cuenta equivocada.

        Esperada : ${var.expected_account_id}
        Actual   : ${data.aws_caller_identity.actual.account_id}

        Revisa AWS_PROFILE. Si has abierto una terminal nueva, la variable se
        perdio y estas usando el perfil por defecto.
      EOT
    }
  }
}
