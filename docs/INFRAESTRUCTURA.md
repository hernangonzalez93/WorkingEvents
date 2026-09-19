# La infraestructura, fichero a fichero

Todo lo que hay en [`infra/`](../infra/), qué crea cada fichero y por qué está escrito así. La
Lambda tiene su propio documento, [LAMBDA](LAMBDA.md).

---

## 1. Convenciones

Se siguen las del proyecto TestEnforce:

- **Comentarios en español sin tildes**, que explican el porqué y no solo el qué.
- **Un guardia de cuenta** que detiene el plan si las credenciales apuntan a otra cuenta.
- **Etiquetas por defecto** en todos los recursos, para poder separar el gasto por proyecto.
- **El estado en S3**, en el bucket compartido y con una clave propia.
- **Un interruptor de apagado** en `apagado.tf`.

## 2. Los ficheros

| Fichero | Qué crea |
|---|---|
| `versions.tf` | Nada: versiones de Terraform y de los proveedores, y dónde se guarda el estado |
| `providers.tf` | Nada: la región y las etiquetas por defecto |
| `variables.tf` | Nada: los valores configurables |
| `cuenta.tf` | El guardia de cuenta |
| `notificaciones.tf` | El topic de SNS y la suscripción por correo |
| `cola.tf` | La cola principal, la de mensajes muertos y el permiso para EventBridge |
| `eventos.tf` | El bus propio, la regla de filtrado y su destino |
| `lambda.tf` | La función, su rol, sus permisos, sus logs y su conexión con la cola |
| `alarmas.tf` | El topic de avisos técnicos, un filtro de métricas y tres alarmas |
| `apagado.tf` | El interruptor general y el apagado nocturno opcional |
| `outputs.tf` | Nada: los valores que se muestran después de aplicar |

## 3. `versions.tf`: dónde vive el estado

El **estado** es el mapa que relaciona lo que dice el código con lo que existe de verdad en
AWS. Si se pierde, Terraform deja de saber qué recursos son suyos, y esos recursos se quedan
huérfanos en la cuenta, cobrando sin que nadie los gobierne.

Por eso vive en S3 y no en el disco:

- Se reutiliza el bucket que creó el bootstrap de TestEnforce, con otra clave
  (`workingevents/terraform.tfstate`). Crear un segundo bucket no aportaría nada.
- El nombre del bucket **no está en el código**, porque contiene el número de cuenta. Se pasa
  con `terraform init -backend-config="bucket=<bucket-de-estado>"`.
- `use_lockfile = true` impide que dos `apply` simultáneos se pisen, sin necesidad de una
  tabla de DynamoDB (disponible desde Terraform 1.10).

Hay dos proveedores: `aws` para los recursos y `archive` para empaquetar en `.zip` el código
de la Lambda.

## 4. `providers.tf`: el perfil y las etiquetas

- **El perfil no está fijado en el código.** Se toma de la variable de entorno `AWS_PROFILE`.
  Así el mismo código sirve desde el portátil y desde un pipeline, que recibirá credenciales
  temporales sin ningún perfil.
- **`default_tags`** pone `Project = WorkingEvents` en todo recurso que admita etiquetas. Esta
  cuenta se comparte con TestEnforce, y sin etiquetas los gastos de los dos proyectos se
  mezclarían en Cost Explorer.

## 5. `cuenta.tf`: el guardia de cuenta

```hcl
resource "terraform_data" "guardia_de_cuenta" {
  lifecycle {
    precondition {
      condition = data.aws_caller_identity.actual.account_id == var.expected_account_id
      ...
```

Se evalúa **durante el plan, antes de crear nada**. Existe porque en TestEnforce ya ocurrió lo
contrario: un plan guardado con un perfil se aplicó con otro, y los recursos aparecieron en la
cuenta equivocada. Basta abrir una terminal nueva para perder `AWS_PROFILE` y acabar usando el
perfil por defecto sin darse cuenta.

`expected_account_id` **no tiene valor por defecto**: va en `terraform.tfvars`, que no se
versiona, para que el número de cuenta no aparezca en el repositorio público. Una validación
comprueba que sean 12 dígitos.

En la salida del plan se ve que el guardia ha pasado: aparece `input = "<ID_CUENTA>"` en lugar
de un error.

## 6. `notificaciones.tf`: SNS y el correo

### 6.1 El topic

Un **topic** de SNS es un tablón de anuncios: quien tiene algo que decir lo publica, y quien
quiere enterarse se suscribe. Ninguno de los dos conoce al otro.

### 6.2 El recorrido del correo, de fichero en fichero

El correo pasa por tres ficheros antes de llegar a AWS:

```
terraform.tfvars   ->   variables.tf   ->   notificaciones.tf   ->   AWS (Subscribe)
 (el VALOR)             (la CASILLA)         (dónde se USA)
```

**`terraform.tfvars`, el valor.** Es el único sitio donde está escrito el correo. Terraform
carga automáticamente cualquier fichero que se llame exactamente `terraform.tfvars`. Está en
`.gitignore`.

**`variables.tf`, la casilla.** Una analogía: `variables.tf` es un formulario con casillas
vacías, y `terraform.tfvars` es quien lo rellena.

| Línea | Significado |
|---|---|
| `variable "email_alertas"` | Crea la casilla. El nombre tiene que coincidir con el de `terraform.tfvars` |
| `type = string` | Solo admite texto |
| `default = ""` | Si nadie la rellena, queda vacía. Así se puede aplicar la infraestructura antes de decidir el correo |
| `sensitive = true` | Terraform no la muestra en pantalla: aparece `(sensitive value)` |

**`notificaciones.tf`, dónde se usa.**

```hcl
resource "aws_sns_topic_subscription" "correo" {
  count     = nonsensitive(var.email_alertas) != "" ? 1 : 0
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "email"
  endpoint  = var.email_alertas
  lifecycle {
    create_before_destroy = true
  }
}
```

| Línea | Significado |
|---|---|
| `resource "aws_sns_topic_subscription" "correo"` | Dos nombres distintos: el **tipo** de recurso, que define el proveedor, y el **apodo** que le pones tú para referirte a él. AWS nunca ve el apodo |
| `count` | **Cuántas copias** crear: 1 si hay correo, 0 si no. Por eso en el plan aparece como `correo[0]`, la posición 0 |
| `nonsensitive(...)` | Terraform no deja usar un valor sensible para decidir cuántos recursos crear. Esto le quita la marca solo para la comprobación, sin mostrar el correo |
| `topic_arn` | A qué topic se suscribe. Un **ARN** es el identificador único de cualquier cosa en AWS, como el DNI de un recurso |
| `aws_sns_topic.alertas.arn` | Una **referencia** a otro recurso. De ella Terraform deduce que tiene que crear primero el topic |
| `protocol = "email"` | Por qué canal se entrega. Podría ser `sms`, `sqs`, `lambda`, `https`… |
| `endpoint = var.email_alertas` | La única línea donde se usa el correo |
| `create_before_destroy` | Si se cambia el correo, crea la suscripción nueva antes de borrar la vieja, para que nunca quede un momento sin suscriptor |

**AWS.** Al aplicar, Terraform llama a la operación `Subscribe` de SNS. SNS crea la suscripción
en estado **pendiente** y envía un correo de confirmación. **Hasta que no se pulsa el enlace, no
llega ninguna alerta.** Es a propósito: impide que cualquiera suscriba tu correo a un topic
ajeno. Es el fallo más habitual al montar esto: todo parece correcto y no llega ningún correo.

Para comprobar el estado:

```powershell
aws sns list-subscriptions-by-topic --topic-arn <arn-del-topic> --query "Subscriptions[].SubscriptionArn" --output text
```

Si responde `PendingConfirmation`, todavía falta el clic.

### 6.3 Tres cosas que se descubrieron al comprobarlo

**1. El estado de Terraform es una foto, no una cámara en directo.** Después de confirmar la
suscripción, AWS decía `PendingConfirmation: false`, pero el estado de Terraform seguía diciendo
`pending_confirmation = true`. El estado se guardó al hacer `apply`, **antes** del clic, y no se
actualiza hasta el siguiente `plan`. No es un error.

**2. `sensitive` oculta, pero no cifra.** En pantalla sale `(sensitive value)`, pero dentro del
estado guardado en S3 el correo está en texto normal. Lo que protege el estado de verdad es el
bucket: cifrado, privado y con el acceso público bloqueado.

**3. Cualquiera que reciba una alerta puede darte de baja.** La suscripción se confirmó con el
enlace del correo, sin credenciales (`ConfirmationWasAuthenticated: false`). Cada alerta lleva un
enlace de baja al final, y si se pulsa, por ti o por alguien a quien le reenvíes una alerta,
la suscripción se borra sin pedir contraseña. Un `terraform apply` la vuelve a crear, pero hay
que confirmarla de nuevo.

## 7. `cola.tf`: la cola y su red de seguridad

### 7.1 La cola de mensajes muertos (DLQ)

Es el hospital de los mensajes que no hay forma de procesar. Sin ella, un mensaje que siempre
falla, por ejemplo con un JSON corrupto, reaparecería una y otra vez para siempre, y cada
reintento invocaría la Lambda. Guarda los mensajes **14 días**, el máximo, para poder
investigarlos con calma.

### 7.2 La cola principal

| Ajuste | Valor | Por qué |
|---|---|---|
| `visibility_timeout_seconds` | **180** | Cuánto tiempo queda invisible un mensaje mientras se procesa. AWS recomienda **6 veces el timeout de la Lambda** (30 s). Si fuera menor, el mensaje reaparecería mientras todavía se está procesando: correo duplicado y coste duplicado |
| `message_retention_seconds` | 4 días | Si nadie lo recoge en ese plazo, algo está roto de todas formas |
| `receive_wait_time_seconds` | **20** | *Long polling*: si la cola está vacía, la pregunta espera hasta 20 s antes de responder "nada". Menos peticiones facturables y menos latencia |
| `redrive_policy` | 3 intentos | Tras 3 intentos fallidos, el mensaje se aparta a la DLQ |

Un mensaje en SQS **no se borra al leerlo**: se vuelve invisible. Si quien lo leyó confirma que
lo procesó, se borra. Si no confirma, porque falló o se cayó, el mensaje reaparece y otro lo
intenta. Así no se pierde nada por el camino. Se ve en acción en
[PRUEBA-MANUAL](PRUEBA-MANUAL.md#9-el-visibility-timeout-descubierto-por-accidente).

### 7.3 El permiso para que EventBridge deposite mensajes

Por defecto, una cola solo acepta mensajes de su dueño, y EventBridge es otro servicio. **Sin
este permiso, la regla se dispararía, intentaría entregar el mensaje y fallaría en silencio**,
con la cola vacía y sin ningún error a la vista. Es uno de los fallos más habituales al montar
esta arquitectura.

La condición `aws:SourceArn` evita abrir la cola a todo EventBridge: solo acepta mensajes de
**esta regla concreta**.

## 8. `eventos.tf`: el bus, la regla y el destino

### 8.1 Un bus propio

Toda cuenta tiene un bus `default`, donde también caen los eventos de los propios servicios de
AWS. Con un bus propio, aquí solo circula lo de este proyecto: los patrones son más simples y
los permisos más acotados. No cuesta nada: se paga por evento publicado.

### 8.2 La regla

```hcl
event_pattern = jsonencode({
  source        = ["workingevents.api"]
  "detail-type" = ["ResenyaEnviada"]
  detail = {
    calificacion = [{ numeric = ["<=", var.umbral_calificacion] }]
  }
})
```

El patrón es una plantilla, y la comparación es **por estructura**: cada clave del patrón tiene
que existir en el evento, con uno de los valores listados. Tienen que cumplirse **todas** las
condiciones.

`numeric` hace que la calificación se compare como número. Sin él, `["1","2","3"]` compararía
texto, y la calificación tiene que llegar como número, no como `"2"`.

`state = var.flujo_activo ? "ENABLED" : "DISABLED"` conecta la regla con el interruptor
general.

### 8.3 El destino

Una regla sin destino no hace nada: encaja el evento y lo descarta. El destino es la cola, y
recibe el **evento entero**, sin `input_transformer`, para que la Lambda tenga también los
metadatos que añade EventBridge: el identificador del evento y la hora.

## 9. `apagado.tf`: el freno de mano

Aquí **no hay nada que se pague por horas**. El riesgo real es el bucle desbocado, y por eso hay
tres niveles de freno, de menos a más drástico:

| Nivel | Cómo | Qué hace |
|---|---|---|
| **1** | `flujo_activo = false` y `apply` | Corta en dos sitios: la **regla** deja de enrutar y el **event source mapping** deja de consumir la cola. No se destruye nada, y lo que haya en la cola espera hasta 4 días. Se revierte con `true` |
| **2** | `apagado_nocturno = true` | Cada noche, a las 22:00 hora de Madrid, **deshabilita la regla**. Solo cierra la entrada: la Lambda termina lo que ya estaba en la cola, así que nada queda a medias |
| **3** | `terraform destroy` | Lo elimina todo. Es barato de rehacer porque no hay datos que perder |

**`apagado_nocturno` viene desactivado**, al contrario que en TestEnforce. Allí olvidarse algo
encendido costaba dinero cada hora; aquí, un apagado automático solo conseguiría que al día
siguiente el laboratorio no funcionase sin saber por qué. Tendrá sentido en la Fase 8, cuando la
web y la API vivan en servicios que sí se pagan por horas.

**Cuidado al mezclar los niveles 1 y 2.** Si el horario nocturno deshabilita la regla y al día
siguiente se lanza `terraform apply`, Terraform verá que el código dice `ENABLED`, que la
realidad dice `DISABLED`, y la volverá a habilitar. Eso se llama **deriva de configuración**
(*drift*), y aquí es el comportamiento que se quiere: aplicar significa "quiero que esto
funcione". Para apagar de forma que resista a un `apply`, se usa el nivel 1.

El apagado nocturno usa un **destino universal** de EventBridge Scheduler
(`arn:aws:scheduler:::aws-sdk:eventbridge:disableRule`): el planificador llama directamente a la
API de AWS, sin una Lambda intermedia. Su rol solo puede hacer `events:DisableRule` sobre esta
regla.

## 10. `lambda.tf`

Se explica entero en [LAMBDA](LAMBDA.md#7-la-infraestructura-lambdatf). Y `alarmas.tf`, en
[OBSERVABILIDAD](OBSERVABILIDAD.md).

## 11. `outputs.tf`

Muestra, después de aplicar, lo que se necesita para trabajar: el nombre del bus (que usa la
API), las URLs de las colas, el ARN del topic, el estado del interruptor, el comando para ver
los logs de la Lambda en directo y un recordatorio de confirmar la suscripción.

## 12. Planificar y aplicar

```powershell
cd infra
$env:AWS_PROFILE = '<tu-perfil>'
terraform plan -out=plan.tfplan
terraform apply plan.tfplan
```

Dos cosas que conviene saber sobre los planes guardados:

- **Al aplicar un plan guardado, Terraform no pregunta `yes`**: la confirmación fue generar el
  plan.
- **Un plan guardado lleva las variables congeladas dentro.** Si después de generarlo se cambia
  `terraform.tfvars`, hay que volver a hacer el plan. Así fue como se añadió el correo, que
  todavía no estaba cuando se generó el primer plan.

| Fase | Recursos creados |
|---|---|
| 2 | 9: bus, regla, destino, dos colas, permiso de la cola, topic, suscripción y guardia |
| 4 | 5: grupo de logs, rol, permisos, función y event source mapping |
| 6 | 6: topic de operaciones, su suscripción, un filtro de métricas y tres alarmas. Además se actualizó la Lambda por un cambio de un comentario |
