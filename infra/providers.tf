provider "aws" {
  region = var.region

  # A proposito NO se fija aqui el perfil: se toma de la variable de entorno
  # AWS_PROFILE. Asi el mismo codigo sirve desde tu equipo con SSO y desde un
  # pipeline, donde las credenciales llegan por OIDC y no hay ningun perfil.

  # Estas etiquetas se aplican solas a todo recurso que las admita. Son lo que
  # permite separar el gasto de ESTE proyecto del de TestEnforce en Cost
  # Explorer: comparten cuenta, asi que sin etiquetas la factura se mezcla.
  default_tags {
    tags = {
      Project     = "WorkingEvents"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
