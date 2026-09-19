terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    # Empaqueta el codigo de la Lambda en un .zip. Lambda no acepta una
    # carpeta: recibe un unico fichero comprimido.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # El estado se guarda en S3, no en tu disco. La razon: el estado es el mapa
  # que relaciona lo que dice el codigo con lo que existe de verdad en AWS. Si
  # se pierde, Terraform deja de saber que recursos son suyos y se quedan
  # huerfanos en la cuenta, cobrando sin que nadie los gobierne.
  #
  # Se reutiliza el mismo bucket que ya creo el bootstrap de TestEnforce: un
  # bucket de estado sirve para varios proyectos siempre que cada uno use una
  # `key` distinta. Crear otro bucket no aportaria nada y habria que mantenerlo.
  #
  # El nombre del bucket NO esta escrito aqui porque lleva dentro el numero de
  # cuenta. Se pasa al inicializar:
  #   terraform init -backend-config="bucket=<nombre-del-bucket>"
  #
  # use_lockfile impide que dos `apply` a la vez se pisen, sin necesidad de una
  # tabla de DynamoDB aparte (disponible desde Terraform 1.10).
  backend "s3" {
    key          = "workingevents/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
