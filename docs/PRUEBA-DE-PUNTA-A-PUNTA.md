# La prueba de punta a punta

La primera vez que el flujo completo funcionó: reseña → API → EventBridge → SQS → event source
mapping → Lambda → SNS → correo. Y todo lo que enseñaron los logs, incluidas dos cosas que se
habían explicado mal.

---

## 1. Qué se probó

Con la API en local, se enviaron tres reseñas, una detrás de otra:

| Reseña | Qué se esperaba |
|---|---|
| 2★ *"El pedido llego tarde y roto. Nadie contesta al telefono, pesimo servicio."* | Correo: el texto es negativo |
| 1★ *"Llego el martes."* | Correo: calificación mínima |
| 3★ *"Cumple su funcion."* | Sin correo, pero registrada en el log |

## 2. Resultado

| Reseña | Puntuación | Sentimiento | ¿Alerta? | Motivo |
|---|---|---|---|---|
| 2★ | **-8** | NEGATIVO | ✉️ Sí | el texto es negativo |
| 1★ | 0 | NEUTRO | ✉️ Sí | calificación mínima (1 estrella) |
| 3★ | 0 | NEUTRO | No | ni el texto es negativo ni la calificación es la mínima |

Llegaron **exactamente dos correos**, con las tildes bien. Al final, la cola principal y la DLQ
estaban **vacías**: el portero borró los tres mensajes y ninguno falló.

## 3. Los logs, línea a línea

```
INIT_START Runtime Version: python:3.13...
[INFO]  Found credentials in environment variables.
START RequestId: ba137e82-...
[INFO]  {"resenya": "rev-1cbc...", "calificacion": 2, "puntuacion": -8.0, "sentimiento": "NEGATIVO", "alerta": true, ...}
END RequestId: ba137e82-...
REPORT RequestId: ba137e82-...  Duration: 287.13 ms  Billed Duration: 649 ms  Memory Size: 128 MB  Max Memory Used: 93 MB  Init Duration: 360.98 ms
```

| Línea | Qué es |
|---|---|
| `INIT_START` | AWS prepara un **contenedor nuevo**: el arranque en frío |
| `Found credentials in environment variables.` | `boto3` encontró las credenciales del rol (sección 9) |
| `START RequestId` | El portero despierta a la función |
| La línea JSON | El código: `procesar()` |
| `END` | Termina la invocación |
| `REPORT` | **La factura**: cuánto duró, cuánto se cobra y cuánta memoria usó |

## 4. Tres invocaciones, no un lote de tres

Se esperaba que el portero juntara las tres reseñas en un solo lote. No lo hizo: hubo **tres
invocaciones, de un mensaje cada una**.

La razón: `batch_size = 10` es un **máximo, no una espera**. Las reseñas llegaron separadas por
décimas de segundo, y cada vez que el portero preguntaba solo había una en la cola. Se lleva lo
que hay en ese momento.

Existe un ajuste para que espere a llenar el lote, `maximum_batching_window_in_seconds`, pero
**no interesa**: las alertas tienen que ser inmediatas, y esperar las retrasaría. Con mucho
tráfico, los lotes se llenarían solos.

## 5. Dos arranques en frío, y el límite de 2 en acción

| # | Reseña | `Duration` | `Init Duration` | `Billed Duration` |
|---|---|---|---|---|
| 1 | 2★ | 287 ms | **361 ms** | 649 ms |
| 2 | 1★ | 314 ms | **447 ms** | 761 ms |
| 3 | 3★ | **9,7 ms** | — | 10 ms |

Lo que pasó, en orden:

1. **Llega la reseña 1.** No hay ningún contenedor, así que AWS arranca el primero (361 ms).
2. **Llega la reseña 2 con el contenedor 1 todavía ocupado.** AWS arranca un segundo contenedor
   (447 ms). Se ve `maximum_concurrency = 2` en acción: son las dos copias simultáneas
   permitidas.
3. **Llega la reseña 3** con un contenedor ya libre y **caliente**: no hay arranque y tarda
   9,7 ms.

El grupo de logs lo confirma: tiene **dos *log streams***, uno por contenedor. Es lo que cubre
el `:*` del permiso de logs.

## 6. Lo que dicen los números

- **El arranque en frío también se factura.** 287 + 361 = 648, y se cobraron 649 ms. 314 + 447
  = 761, y se cobraron 761 ms.
- **Por qué la tercera fue 30 veces más rápida.** Hay dos causas a la vez, y conviene no
  mezclarlas: el contenedor estaba caliente, pero además **esa reseña no envió correo**. Las dos
  primeras abrieron por primera vez una conexión HTTPS con SNS, que es lento. No es una
  comparación limpia de frío contra caliente.
- **Memoria: 93 MB de 128.** Casi todo es `boto3` cargado en memoria. Hay margen, pero no mucho.
  Habrá que vigilarlo en la Fase 7, al añadir la librería de Anthropic.

## 7. Coste y latencia

- **Coste:** 1,42 s facturados × 0,125 GB = **0,18 GB-s**, de los 400.000 gratuitos al mes.
- **Latencia de punta a punta:** la API publicó a las 13:37:25 UTC y la Lambda analizó la
  primera reseña a las 13:37:28. Son **unos 3 segundos**, contando el arranque en frío.

## 8. Lo que debería verse en la consola

| Dónde | Qué se ve |
|---|---|
| Lambda → Configuration → Triggers | La caja SQS conectada, estado `Enabled` |
| CloudWatch → grupo de logs de la función | Dos *log streams* |
| Lambda → Monitor | `Invocations` = 3, `Errors` = 0, `ConcurrentExecutions` con un pico de 2 |
| SQS → la cola → Monitoring | `NumberOfMessagesReceived` = 3, `NumberOfMessagesDeleted` = 3 y `NumberOfEmptyReceives` subiendo |

## 9. Lo que la prueba corrigió

Dos cosas se habían explicado mal antes de la prueba, y los logs lo dejaron claro. Aquí queda la
versión correcta:

**1. `LastProcessingResult` no sirve para colas SQS.** Se había dicho que mostraría
`No records processed` y luego `OK`. En realidad se queda en `null` antes y después de
procesar: ese campo está pensado para otras fuentes. Para saber si el portero trabaja hay que
mirar las métricas y los logs.

**2. Cómo le llegan las credenciales a la Lambda.** Se había dicho que, dentro de AWS, el SDK
llegaría al último punto de su cadena de búsqueda, "el rol del sitio donde corre". El log dice
`Found credentials in environment variables`: Lambda obtiene las credenciales **temporales**
del rol y las mete en variables de entorno antes de ejecutar el código, así que el SDK las
encuentra en el **primer** punto de la cadena. Siguen siendo las del rol y siguen caducando
solas; solo cambia el camino por el que llegan. La conclusión no cambia: **el código no lleva
credenciales**.

## 10. Repetirla

```powershell
dotnet run --project src/api
```

En otra terminal:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:5080/resenyas -ContentType 'application/json' -Body '{"comentario":"Llego tarde y roto, pesimo servicio","calificacion":2,"email":"cliente@ejemplo.com"}'
aws logs tail /aws/lambda/workingevents-analizador --since 5m --region eu-west-1
```

Desde Git Bash, el segundo comando necesita `MSYS_NO_PATHCONV=1` delante, porque si no, Git
Bash convierte `/aws/lambda/...` en una ruta de Windows ([ENTORNO](ENTORNO.md#5-trampas-de-git-bash-en-windows)).
