# La prueba manual: `PutEvents` pieza a pieza

Antes de escribir la API se publicaron eventos **a mano** con el CLI de AWS, para comprobar que
EventBridge y SQS funcionaban por sí solos y que el filtro hacía su trabajo. Este documento
explica qué se hizo, pieza a pieza, y lo que se aprendió por el camino.

---

## 1. Qué se quería demostrar

Se enviaron dos reseñas opuestas **en una sola llamada**:

| Evento | Calificación | Comentario |
|---|---|---|
| `rev-001` | **2** | *"El pedido llego con dos dias de retraso y el producto venia roto…"* |
| `rev-002` | **5** | *"Todo perfecto, llego antes de lo previsto…"* |

Hacerlo en la misma llamada es deliberado: mismo bus, mismo instante, mismas condiciones. Si
solo llega una a la cola, la única explicación posible es el filtro.

## 2. Cómo se le habla a AWS

Cada servicio de AWS funciona como **una ventanilla con una lista fija de trámites**. Cada
trámite, u **operación**, tiene un nombre y un formulario con campos concretos. EventBridge
tiene, entre otras:

| Operación | Qué hace |
|---|---|
| `PutEvents` | Publicar eventos en un bus |
| `PutRule` | Crear o modificar una regla |
| `PutTargets` | Decirle a una regla adónde enviar |
| `DescribeRule` | Consultar cómo está una regla |
| `DisableRule` | Deshabilitar una regla (la usa el apagado nocturno) |

Hay varias puertas que llevan a las **mismas operaciones**:

| Puerta | Dónde se usa en este proyecto |
|---|---|
| **Terraform** | Al aplicar, llamó por dentro a `CreateEventBus`, `PutRule`, `PutTargets`, `Subscribe`… |
| **AWS CLI**, el programa `aws` | En esta prueba manual |
| **SDK de .NET** | En la API, en la Fase 3 |
| **Consola web** | Cada botón llama a una de estas operaciones |

## 3. Qué es `PutEvents`

*Put* significa "poner" o "depositar". **`PutEvents` es la operación que deposita eventos en un
bus**, y es la única forma de que un evento propio entre en EventBridge. La API de la Fase 3
llama exactamente a esta misma operación: la prueba manual fue un ensayo de lo que haría el
código.

## 4. El comando, pieza a pieza

```
aws events put-events --entries file://pruebas/eventos.json --region eu-west-1
```

| Pieza | Qué es |
|---|---|
| `aws` | El programa AWS CLI |
| `events` | **A qué servicio** va la petición. Se llama `events` y no `eventbridge` por historia: EventBridge nació en 2019 a partir de *CloudWatch Events*, y el CLI conservó el nombre viejo. Por el mismo motivo el recurso de Terraform se llama `aws_cloudwatch_event_rule` |
| `put-events` | **Qué operación**: `PutEvents` escrito al estilo del CLI, en minúsculas y con guion |
| `--entries` | El campo con la lista de eventos. Admite hasta 10 por llamada |
| `file://pruebas/eventos.json` | "Coge el valor de este fichero". Escribir el JSON en la terminal obliga a escapar cada comilla |
| `--region eu-west-1` | **En qué región**. El bus vive en Irlanda; en Fráncfort no existe |

Y una pieza que no se ve: `AWS_PROFILE`. Con ella, el CLI **firma** la petición con las
credenciales del perfil. Sin firma, AWS la rechaza.

## 5. El formulario: los cuatro campos de cada evento

El contenido de [`pruebas/eventos.json`](../pruebas/eventos.json) para la primera reseña:

```json
{
  "Source": "workingevents.api",
  "DetailType": "ResenyaEnviada",
  "EventBusName": "workingevents-bus",
  "Detail": "{\"id\": \"rev-001\", \"comentario\": \"El pedido llego...\", \"calificacion\": 2, \"email\": \"cliente.enfadado@ejemplo.com\"}"
}
```

| Campo | Qué es | Por qué importa |
|---|---|---|
| `Source` | **Quién** envía el evento. Por convención, el nombre de la aplicación | La regla solo acepta este origen |
| `DetailType` | **Qué ha pasado**, en pasado, porque es un hecho y no una orden | La regla solo acepta este tipo |
| `EventBusName` | **A qué bus** va | Si se omite, va al bus `default`, donde no está la regla, y el evento se pierde sin error |
| `Detail` | **El contenido**: la reseña | Dentro va la `calificacion` que mira el filtro |

### Por qué `Detail` lleva esas barras `\"`

El valor de `Detail` empieza y termina con comillas: **es un texto**, no un objeto JSON, y
dentro de ese texto hay otro JSON escrito. Como el JSON de dentro también tiene comillas, cada
una lleva una barra invertida delante. `\"` significa "esta comilla es parte del texto, no lo
cierra".

```
CORRECTO   (texto que contiene JSON):   "Detail": "{\"calificacion\": 2}"
INCORRECTO (objeto JSON):               "Detail": {"calificacion": 2}
```

AWS lo diseñó así, y si recibe la versión incorrecta, rechaza el evento. En Python,
`json.dumps` convierte un objeto en ese texto escapado.

## 6. La respuesta

```json
{
  "FailedEntryCount": 0,
  "Entries": [
    { "EventId": "133094a7-6243-6cde-29a2-47afa186b99b" },
    { "EventId": "71a80a96-4af9-919f-fccd-be5528d4ecab" }
  ]
}
```

| Campo | Significado |
|---|---|
| `FailedEntryCount` | Cuántos eventos se rechazaron **a la entrada**: mal formados, bus inexistente… 0 = entraron los dos |
| `Entries` | Uno por evento, **en el mismo orden** en que se enviaron |
| `EventId` | El identificador único que asigna EventBridge. Es como el **número de seguimiento** de un paquete |

**Aceptado no es lo mismo que entregado.** Esta respuesta solo certifica que EventBridge
**recibió** los eventos, no adónde los llevó. Es como el resguardo de Correos: demuestra que
aceptaron la carta, no que llegara.

## 7. Qué hizo la regla, condición a condición

| Condición del patrón | `rev-001` | `rev-002` |
|---|---|---|
| ¿`source` es `workingevents.api`? | ✅ | ✅ |
| ¿`detail-type` es `ResenyaEnviada`? | ✅ | ✅ |
| ¿`calificacion` ≤ 3? | ✅ (2) | ❌ (5) |
| **Resultado** | **Encaja: va a la cola** | **No encaja: se descarta** |

A la cola llegó **un mensaje**. El de 5 estrellas se descartó en silencio: sin error, sin log,
sin rastro. Si un evento no llega a su destino, EventBridge **no dice por qué**, y la causa
casi siempre es un patrón que no encaja.

**Una confusión frecuente:** al publicar se escribe `Source`, `DetailType` y `Detail`, con
mayúscula, porque así se llaman los campos del formulario de `PutEvents`. Pero en la regla y en
el evento entregado aparecen como `source`, `detail-type` y `detail`. Son los mismos datos
escritos de dos maneras.

## 8. Lo que llegó a la cola: el sobre y la carta

```json
{
  "version": "0",
  "id": "133094a7-6243-6cde-29a2-47afa186b99b",
  "detail-type": "ResenyaEnviada",
  "source": "workingevents.api",
  "account": "<ID_CUENTA>",
  "time": "2026-09-19T09:17:03Z",
  "region": "eu-west-1",
  "resources": [],
  "detail": {
    "id": "rev-001",
    "comentario": "El pedido llego con dos dias de retraso...",
    "calificacion": 2,
    "email": "cliente.enfadado@ejemplo.com"
  }
}
```

La analogía: se lleva una carta a Correos (`Detail`) y se rellena un impreso con el remitente
(`Source`) y el tipo de envío (`DetailType`). Correos la mete en un **sobre** y le estampa un
número de seguimiento, la fecha y la oficina de origen.

| Campo | ¿Quién lo pone? |
|---|---|
| `version` | EventBridge. Es la versión del formato del sobre y siempre vale `"0"` |
| `id` | EventBridge: **es el mismo `EventId` de la respuesta** |
| `detail-type` | Quien publica, en `DetailType` |
| `source` | Quien publica, en `Source` |
| `account` | EventBridge: la cuenta que publicó |
| `time` | EventBridge: cuándo lo recibió. La `Z` significa hora UTC |
| `region` | EventBridge |
| `resources` | Quien publica, aunque es opcional y aquí no se usa |
| `detail` | Quien publica, en `Detail` |

**Fíjate en `detail`:** al publicarlo era un **texto** con barras `\"`. Al entregarlo es un
**objeto**. EventBridge lo convirtió al recibirlo, y por eso la regla puede mirar dentro y leer
`detail.calificacion`.

### El `id` sirve para seguir un evento

El primer `EventId` de la respuesta, `133094a7…`, es exactamente el `id` del sobre que llegó a
la cola. El segundo, `71a80a96…`, **no aparece en ningún sitio**, porque su evento se descartó.
Así se sigue un evento concreto de punta a punta: si una reseña no genera alerta, se busca su
`id`, y si no está en la cola, es que la regla la descartó.

### Las tres capas

SQS solo guarda texto, así que el sobre entero **vuelve a convertirse en texto** para meterlo en
el mensaje. Quedan tres capas, una dentro de otra, como unas matrioskas:

```
Mensaje de SQS
 └── Body  (texto)
      └── Evento de EventBridge  (el sobre)
           └── detail  (la carta: la reseña)
```

La Lambda tiene que abrirlas en orden para llegar al comentario. Lo hace
`extraer_resenya()` en [`alertas.py`](../src/lambda/funcion/alertas.py).

## 9. El visibility timeout, descubierto por accidente

El primer intento de leer la cola falló por un error de ruta de Windows. Al repetirlo, la cola
devolvió **cero mensajes**, y parecía que no había llegado nada. Pero la cola decía esto:

```
ApproximateNumberOfMessages:           0   <- visibles
ApproximateNumberOfMessagesNotVisible: 1   <- EN VUELO
```

El mensaje estaba ahí. **La primera lectura sí había funcionado**, y al leerlo, SQS lo volvió
invisible durante 180 segundos.

Es el **visibility timeout**, el mecanismo central de SQS. La analogía: es como coger una
carpeta de la bandeja de pendientes y ponerla en tu mesa. Mientras está en tu mesa, nadie más
la ve, así que el trabajo no se duplica. Si la terminas, la tiras. Si te vas a comer y no
vuelves, al rato alguien la devuelve a la bandeja para que otro la coja.

## 10. Leer no es borrar

Para eliminar el mensaje de verdad hizo falta una segunda llamada, `delete-message`, con el
**`ReceiptHandle`**: una cadena de unos 400 caracteres que no es el identificador del mensaje,
sino el comprobante de **esa lectura concreta**.

Es lo que garantiza que no se pierda nada: un mensaje solo desaparece cuando alguien confirma
explícitamente que lo ha procesado. Esto es justo lo que automatiza el event source mapping en
la Fase 4. Se explica en [EVENT-SOURCE-MAPPING](EVENT-SOURCE-MAPPING.md).

## 11. Cómo repetirla

```powershell
$env:AWS_PROFILE = '<tu-perfil>'
aws events put-events --entries file://pruebas/eventos.json --region eu-west-1
aws sqs receive-message --queue-url <url-de-la-cola> --max-number-of-messages 10 --wait-time-seconds 10
aws sqs delete-message --queue-url <url-de-la-cola> --receipt-handle <receipt-handle>
```

La URL de la cola aparece en los *outputs* de Terraform (`cola_url`).

Con la Fase 4 desplegada, **la Lambda consumirá los mensajes antes que tú**. Para repetir la
prueba tal cual, primero hay que parar el consumo con `flujo_activo = false`… pero eso también
deshabilita la regla. La forma más sencilla de ver ahora el ciclo completo es la prueba de
[PRUEBA-DE-PUNTA-A-PUNTA](PRUEBA-DE-PUNTA-A-PUNTA.md).
