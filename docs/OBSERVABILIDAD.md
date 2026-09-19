# Observabilidad: enterarse de que algo falla

Tres alarmas de CloudWatch que avisan por correo cuando algo va mal, sin que haga falta ir a
mirar. Infraestructura en [`infra/alarmas.tf`](../infra/alarmas.tf).

Todo se probó **provocando fallos a propósito**, y los tiempos de este documento son los
reales.

---

## 1. Resultado

| Prueba | Fallo provocado | Alarma | Saltó | Volvió a OK |
|---|---|---|---|---|
| **A** | Invocar la Lambda con un evento vacío: la función entera revienta | `errores-lambda` | **47 s** después | 6 min después, sola |
| **B** | Una reseña sin comentario: el mensaje falla una y otra vez | `mensajes-fallidos` | **105 s** después del primer fallo | 7 min después del último fallo, sola |
| **B** | El mismo mensaje, tras su tercer fallo, cae en la DLQ | `dlq-con-mensajes` | **11 min** después del primer fallo | Solo cuando se borró el mensaje (**Prueba C**) |

Llegaron **seis correos**: un ALARM y un OK por cada alarma.

## 2. Log, métrica y alarma

| | Qué es | Analogía | Ejemplo |
|---|---|---|---|
| **Log** | Un texto que escribe el código | El **cuaderno de bitácora**: lo cuenta todo, pero alguien tiene que leerlo | `Fallo al procesar el mensaje 7a743987…` |
| **Métrica** | Un número a lo largo del tiempo | El **termómetro**: no explica nada, pero se puede vigilar | Mensajes en la DLQ: 0, 0, 1, 1… |
| **Alarma** | Un vigilante sobre una métrica | El **detector de humo**: no hay que mirarlo, suena solo | Si la DLQ pasa de 0, avisa |

Antes de esta fase había logs y métricas, pero **nadie vigilaba**. Un mensaje podía pasar 14
días en la DLQ sin que nadie se enterase.

## 3. Estados y avisos

| Estado | Significado |
|---|---|
| **OK** | La condición no se cumple |
| **ALARM** | La condición se cumple |
| **INSUFFICIENT_DATA** | No hay datos suficientes para decidir. Es el estado con el que nace toda alarma |

Una alarma **avisa al cambiar de estado**, no en cada comprobación. `alarm_actions` avisa al
pasar a ALARM, y `ok_actions` al volver a OK: un correo cuando salta y otro cuando se resuelve.

## 4. Anatomía de una alarma

Con la de la DLQ como ejemplo:

| Línea | Valor | Significado |
|---|---|---|
| `namespace` + `metric_name` | `AWS/SQS` + `ApproximateNumberOfMessagesVisible` | **Qué** métrica vigila. El *namespace* es la familia: `AWS/SQS`, `AWS/Lambda` o una propia |
| `dimensions` | `QueueName = …-dlq` | **De qué recurso**. Sin esto, serían todas las colas de la cuenta |
| `period` | `60` | La comprueba minuto a minuto |
| `statistic` | `Maximum` | Dentro de cada minuto, se queda con el valor más alto |
| `threshold` + `comparison_operator` | `0` + `GreaterThanThreshold` | La condición: mayor que 0 |
| `evaluation_periods` | `1` | Basta un minuto que la cumpla |
| `treat_missing_data` | `notBreaching` | Qué hacer si no hay datos (sección 5) |

## 5. `treat_missing_data`: cuando no hay datos

SQS deja de publicar métricas de una cola que lleva horas sin actividad. Lambda no publica
`Errors` si no hay invocaciones. Y la métrica de los logs solo recibe datos cuando algo falla.
En los tres casos, **"no hay datos" es la situación normal**. Con `notBreaching`, se trata como
"todo bien". Sin esa línea, las alarmas pasarían casi todo el tiempo en INSUFFICIENT_DATA.

Las pruebas mostraron los dos caminos hacia OK:

| Alarma | Motivo del OK |
|---|---|
| `errores-lambda` | *no datapoints were received for 1 period and 1 missing datapoint was treated as [NonBreaching]*: no hubo dato |
| `dlq-con-mensajes` | *1 datapoint [0.0] was not greater than the threshold (0.0)*: sí hubo dato, y era un cero |

Y un efecto a tener en cuenta: CloudWatch **no da un dato por perdido al momento**, sino que
espera unos minutos por si llega tarde. Por eso `errores-lambda` tardó 6 minutos en volver a OK,
y `mensajes-fallidos` siguió en ALARM durante todos los reintentos. Los fallos se repetían cada 3
minutos y nunca llegó a haber un hueco suficiente para darlos por terminados.

## 6. Tres redes, cada una para un fallo distinto

| # | Alarma | Qué vigila | Qué detecta |
|---|---|---|---|
| 1 | `mensajes-fallidos` | Una métrica **fabricada a partir de los logs** | Falla **un mensaje suelto** |
| 2 | `errores-lambda` | `Errors` de `AWS/Lambda` | Falla **la función entera** |
| 3 | `dlq-con-mensajes` | Los mensajes de la DLQ | Un mensaje ha fallado **tres veces** y ya nadie lo va a reintentar |

Ninguna sustituye a las otras:

- **La 1 ve lo que la 2 no ve.** Si falla un mensaje suelto, `handler()` captura el error y
  responde con normalidad, así que para Lambda la invocación **salió bien** y `Errors` no sube.
- **La 2 ve lo que la 1 no ve.** Si la función falla antes de llegar al bucle de mensajes, no se
  escribe "Fallo al procesar". Fue justo lo que pasó en la Prueba A.
- **La 3 no se apaga sola.** Las alarmas 1 y 2 vuelven a OK en cuanto dejan de producirse
  errores. La 3 sigue en ALARM mientras quede un mensaje en la DLQ, porque el problema sigue
  sin resolver: hay una reseña que nadie ha analizado.

## 7. Convertir un log en métrica

La alarma 1 necesita una métrica que AWS no publica. La fabrica un **filtro de métricas**: lee
los logs de la Lambda según llegan y, por cada línea que contiene `"Fallo al procesar el
mensaje"`, suma 1 a la métrica `WorkingEvents/MensajesFallidos`.

```hcl
pattern = "\"Fallo al procesar el mensaje\""
```

Las comillas hacen que se busque la frase entera, y no cada palabra por separado.

**La trampa:** el filtro busca ese texto exacto. Si alguien cambia la frase en `manejador.py`,
el filtro deja de contar **sin dar ningún error** y la alarma se queda ciega. Por eso hay un
comentario que lo advierte en los dos lados: en `alarmas.tf` y junto al `logger.exception` de
`manejador.py`.

Y de propina, un aprendizaje sobre las huellas: ese comentario fue el único cambio en el código
de la Lambda, y aun así Terraform la volvió a desplegar. `source_code_hash` detecta cualquier
byte que cambie en el `.zip`, aunque el comportamiento sea el mismo.

## 8. Un topic aparte para los avisos técnicos

| Topic | Qué significa | Destinatario natural |
|---|---|---|
| `alertas-resenyas` | "Un cliente está enfadado" | Atención al cliente |
| `alarmas-operacion` | "El sistema está roto" | Quien mantiene el sistema |

En el laboratorio los dos van al mismo correo, pero se pueden separar poniendo
`email_operaciones` en `terraform.tfvars`.

La suscripción nueva exigió **otro correo de confirmación**, y hubo una confusión: los dos
correos de confirmación tienen el mismo asunto, *"AWS Notification - Subscription
Confirmation"*. Se distinguen por el remitente (*Alarmas WorkingEvents*) y por el topic que
aparece en el texto (`workingevents-alarmas-operacion`).

## 9. Prueba A: la función entera revienta

```powershell
aws lambda invoke --function-name workingevents-analizador --payload '{}' --cli-binary-format raw-in-base64-out salida.json
```

La respuesta fue `StatusCode: 200` y `FunctionError: Unhandled`, con `KeyError: 'Records'`. El
200 significa que **la llamada a Lambda** funcionó; el fallo de **la función** se indica aparte.
Es el mismo patrón que `PutEvents` y que `fetch`.

La alarma saltó 47 segundos después, con este motivo:
*Threshold Crossed: 1 datapoint [1.0] was greater than the threshold (0.0)*.

## 10. Prueba B: un mensaje venenoso

Un **mensaje venenoso** es uno que siempre falla, porque el defecto está en el propio mensaje.
Se usó [`pruebas/evento-defectuoso.json`](../pruebas/evento-defectuoso.json): una reseña de 2
estrellas **sin comentario**. Pasa el filtro de la regla, pero la Lambda falla al abrirla:

```
File "/var/task/alertas.py", line 41, in extraer_resenya
    comentario=carta["comentario"],
KeyError: 'comentario'
```

| Hora | Qué pasó |
|---|---|
| 17:36:03 | Se publica la reseña |
| 17:36:07 | Intento 1: falla |
| 17:37:48 | 🔔 Alarma 1 |
| 17:39:06 | Intento 2: falla, **179 s** después, el *visibility timeout* |
| 17:42:06 | Intento 3: falla, otros **179 s** después |
| 17:45 | SQS aparta el mensaje a la DLQ (`maxReceiveCount = 3`) |
| 17:47:25 | 🔔 Alarma 3 |

Fueron exactamente tres intentos, separados por el *visibility timeout*, y después la DLQ, tal
como se configuró en `cola.tf`.

## 11. Prueba C: qué hacer cuando salta la alarma de la DLQ

Es el procedimiento que seguiría el responsable al recibir la alarma 3.

**1. Mirar el mensaje**, pidiendo todos sus atributos:

```powershell
aws sqs receive-message --queue-url <url-de-la-dlq> --attribute-names All
```

| Atributo | Qué dijo | Para qué sirve |
|---|---|---|
| `MessageId` | `7a743987…` | Es el mismo que aparece en los logs de fallo |
| `DeadLetterQueueSourceArn` | `…:workingevents-resenyas` | **De qué cola vino.** Una DLQ puede servir a varias |
| `ApproximateReceiveCount` | `4` | Los 3 intentos más la lectura para revisarlo. El contador **viaja con el mensaje** |
| El `id` del sobre | `c11441e7…` | El `EventId` que devolvió `put-events`: lleva hasta el origen |
| `detail` | Sin `comentario` | **La causa** |

**2. Diagnosticar y decidir:**

| Opción | Cuándo |
|---|---|
| **Devolverlo a la cola** (*redrive*) | El fallo era pasajero o ya está corregido: SNS caído, un error que ya se arregló… Al reintentarlo, funcionará |
| **Borrarlo** | El mensaje en sí está mal, y reintentarlo fallaría siempre. En un sistema real, antes se guardaría una copia y se avisaría a quien lo produjo |

Aquí era un mensaje venenoso, así que se borró:

```powershell
aws sqs delete-message --queue-url <url-de-la-dlq> --receipt-handle <receipt-handle>
```

**3. Comprobar que la alarma se resuelve.** Se borró a las 17:48:23 y la alarma volvió a OK a
las 17:51:25.

## 12. Tiempos de reacción

| Alarma | De fallo a aviso | Por qué tarda eso |
|---|---|---|
| `errores-lambda` | ~47 s | Lambda publica la métrica directamente |
| `mensajes-fallidos` | ~105 s | Da un rodeo: el log llega a CloudWatch, el filtro lo convierte en métrica y la alarma la evalúa |
| `dlq-con-mensajes` | ~11 min | 3 intentos × 180 s de *visibility timeout*, más el retraso de las métricas de SQS |

## 13. Coste

CloudWatch regala **10 alarmas y 10 métricas personalizadas** al mes. Aquí hay 3 alarmas y 1
métrica personalizada, así que el coste es **$0**.

## 14. Lo que todavía no vigila

- **Una cola atascada.** Si el portero se detuviera con mensajes dentro, no fallaría nada, pero
  `ApproximateAgeOfOldestMessage` de la cola principal crecería sin parar. Sería una cuarta
  alarma natural.
- **Un panel.** Un *dashboard* de CloudWatch con reseñas recibidas, alertas enviadas y fallos
  en una sola pantalla.
- **La API.** Corre en local, así que sus errores no llegan a CloudWatch. Cambiará en la Fase 8.
