# La Lambda

La función que lee las reseñas de la cola, analiza el texto y avisa por correo de las
negativas. Código en [`src/lambda/`](../src/lambda/) e infraestructura en
[`infra/lambda.tf`](../infra/lambda.tf).

---

## 1. Qué es una Lambda

La API corre en una máquina que está encendida todo el rato, esperando peticiones. Una Lambda
funciona al revés: **no hay nada encendido**. Cuando llega trabajo, AWS:

1. Prepara un contenedor, un pequeño ordenador aislado.
2. Mete dentro el código.
3. Ejecuta la función.
4. Si deja de llegar trabajo, apaga el contenedor al cabo de unos minutos.

Se paga **por milisegundo de ejecución**, así que si no llegan reseñas, no cuesta nada. La
analogía: la API es un empleado en plantilla, que cobra aunque no haya clientes, y la Lambda es
un profesional al que se llama por encargo y que cobra por minuto trabajado.

**El arranque en frío.** La primera vez, AWS tiene que preparar el contenedor: descargar el
`.zip`, arrancar Python y ejecutar el código del nivel superior del módulo. Eso lleva unos
cientos de milisegundos. Las siguientes invocaciones reutilizan el contenedor y son mucho más
rápidas. Se midió en la [prueba de punta a punta](PRUEBA-DE-PUNTA-A-PUNTA.md).

## 2. El código

| Fichero | ¿Habla con AWS? | ¿Se puede probar en local sin instalar nada? |
|---|---|---|
| [`analizador.py`](../src/lambda/funcion/analizador.py) | No | ✅ |
| [`alertas.py`](../src/lambda/funcion/alertas.py) | No | ✅ |
| [`analizador_llm.py`](../src/lambda/funcion/analizador_llm.py) (Fase 7) | No: habla con OpenAI o Anthropic | ✅ Todo menos la llamada |
| [`secretos.py`](../src/lambda/funcion/secretos.py) (Fase 7) | **Sí**, con `boto3` | No |
| [`manejador.py`](../src/lambda/funcion/manejador.py) | **Sí**, con `boto3` | No |
| [`comparador.py`](../src/lambda/funcion/comparador.py) (Fase 7) | Sí: es la entrada de la comparadora | No |

La Fase 7 añadió el análisis con IA; se explica en [IA](IA.md).

Toda la lógica está en los dos primeros. `manejador.py` es fino a propósito: solo conecta las
piezas con AWS. El analizador tiene su propio documento,
[ANALISIS-DE-SENTIMIENTO](ANALISIS-DE-SENTIMIENTO.md).

## 3. Qué pasa dentro de la Lambda

```
handler(event)                         <- AWS la llama con un lote de hasta 5 mensajes
  │
  └─ por cada mensaje: procesar()
       ├─ ① extraer_resenya()   abre las 3 capas: Body (texto) → sobre → detail
       ├─ ② analizar()          texto → puntuación + NEGATIVO / NEUTRO / POSITIVO
       ├─ ③ requiere_alerta()   ¿se avisa? ¿por qué?
       ├─ ④ una línea JSON en el log
       └─ ⑤ si hay alerta: sns.publish() → correo
```

## 4. `alertas.py`: capas, decisión y correo

**`extraer_resenya()`** abre las tres capas del mensaje (se explican en
[PRUEBA-MANUAL](PRUEBA-MANUAL.md#las-tres-capas)):

```python
sobre = json.loads(registro["body"])   # el Body es texto: SQS solo guarda texto
carta = sobre["detail"]                # la reseña que publicó la API
```

Si falta cualquier campo, lanza una excepción **a propósito**. Un mensaje así no se arregla
reintentando: tras tres intentos acaba en la cola de mensajes muertos, que es donde tiene que
estar para revisarlo a mano.

**`requiere_alerta()`** decide si se avisa y devuelve el motivo. Se explica en
[ANALISIS-DE-SENTIMIENTO](ANALISIS-DE-SENTIMIENTO.md#4-la-decisión-de-avisar).

**`componer_mensaje()`** escribe el correo. SNS exige que el asunto tenga menos de 100
caracteres y ningún salto de línea. Además, el asunto va sin tildes ni eñes, para no depender
de cómo las muestre cada cliente de correo. El cuerpo no tiene esas limitaciones.

## 5. `manejador.py`

### 5.1 El cliente de SNS se crea fuera de `handler()`

```python
sns = boto3.client("sns")
TOPIC_ARN = os.environ["TOPIC_ARN"]
```

Ese código se ejecuta **una vez por contenedor**, en el arranque en frío. Después, el mismo
contenedor atiende muchas invocaciones y reutiliza el cliente. Crearlo dentro de `handler()`
repetiría el trabajo en cada lote.

No lleva credenciales ni región: dentro de Lambda, el SDK las encuentra solo.

### 5.2 La respuesta por lotes parcial

```python
for registro in event["Records"]:
    try:
        procesar(registro)
    except Exception:
        fallidos.append({"itemIdentifier": registro["messageId"]})

return {"batchItemFailures": fallidos}
```

Imagina un lote de 10 mensajes en el que uno es ilegible:

| | Qué hace AWS | Consecuencia |
|---|---|---|
| **Sin** respuesta parcial | Da por fallido **el lote entero** y lo devuelve a la cola | Los 9 buenos se procesan otra vez: **9 correos duplicados** |
| **Con** respuesta parcial | Solo devuelve el ilegible | Los 9 buenos se borran; el malo se reintenta y, al tercer fallo, va a la DLQ |

**Solo funciona si Terraform lo activa** con `function_response_types =
["ReportBatchItemFailures"]`. Sin esa línea, AWS ignora la lista.

## 6. El correo que llega

```
ASUNTO: ALERTA resenya 2/5 - rev-b0da099c-bc53-44cc-a98d-55d1bb9e0e8a

Se ha recibido una reseña que requiere atención inmediata.

Motivo:        el texto es negativo
Calificación:  2/5
Sentimiento:   NEGATIVO (puntuación -5)
Señales:       tarde (-1), roto (-2), nadie contesta (-2)

Comentario del cliente:
  "El pedido llego tarde y roto. Nadie contesta al telefono."

Contactar a:   cliente.enfadado@ejemplo.com

--
Reseña:        rev-b0da099c-bc53-44cc-a98d-55d1bb9e0e8a
Evento:        67d53897-9da0-a0dc-20fe-7e787aefef28
Recibida:      2026-09-19T11:14:26Z (UTC)
```

Al final están los dos identificadores, el de la reseña y el del evento. Con ellos se puede
seguir la alerta hacia atrás, hasta la petición original.

## 7. La infraestructura: `lambda.tf`

Tiene seis piezas, en el orden en que dependen unas de otras:

| # | Recurso | Qué es |
|---|---|---|
| 1 | `data.archive_file` | Comprime `src/lambda/funcion/` en `infra/build/analizador.zip` |
| 2 | `aws_cloudwatch_log_group` | Dónde escribe la función, con caducidad |
| 3 | `aws_iam_role` | La **identidad** de la función |
| 4 | `aws_iam_role_policy` | Qué puede hacer esa identidad |
| 5 | `aws_lambda_function` | La función: código, identidad y configuración |
| 6 | `aws_lambda_event_source_mapping` | La conexión entre la cola y la función |

### 7.1 El paquete

Lambda no acepta una carpeta: recibe un único fichero comprimido. Solo viaja `funcion/`, sin
las pruebas. El código propio no tiene dependencias; las de la IA (los SDK de Anthropic y
OpenAI) van aparte, en una **capa** ([IA](IA.md#43-una-capa-y-no-todo-en-el-mismo-zip)), y
`boto3` ya viene incluido en Lambda. `excludes` deja fuera las cachés `__pycache__`; se
comprobó creando una a propósito y mirando el `.zip`.

### 7.2 El grupo de logs

Si no se crea aquí, Lambda lo crea sola la primera vez que escribe… **con retención infinita**.
Los logs crecerían y se pagarían para siempre. Creándolo antes, caduca a los 7 días.

### 7.3 El rol: una identidad sin contraseña

| | La API | La Lambda |
|---|---|---|
| Se identifica con | Un **perfil**: un usuario con claves permanentes en el disco | Un **rol**: una identidad sin contraseña que un servicio "se pone" mientras trabaja |
| ¿Caduca? | No | Sí: las credenciales son temporales y se renuevan solas |

La analogía: el perfil es **tu DNI con las llaves de casa**, y el rol es **un uniforme con una
tarjeta de acceso**, que abre ciertas puertas mientras se lleva puesto y caduca solo.

Un rol tiene dos políticas, que responden a dos preguntas distintas:

| Política | Pregunta | Aquí |
|---|---|---|
| **De confianza** (`assume_role_policy`) | ¿**Quién** puede ponerse el uniforme? | Solo el servicio Lambda |
| **De permisos** (`aws_iam_role_policy`) | ¿**Qué puertas** abre? | Las de la tabla siguiente |

### 7.4 Los permisos: lo mínimo, y solo sobre lo suyo

| Bloque | Acciones | Sobre qué |
|---|---|---|
| `LeerLaCola` | `ReceiveMessage`, `DeleteMessage`, `GetQueueAttributes` | Solo esta cola |
| `LeerSuClave` (Fase 7) | `GetSecretValue` | Solo el secreto del proveedor que usa. Con `lexico` este bloque no existe |
| `PublicarAlertas` | `Publish` | Solo este topic |
| `EscribirLogs` | `CreateLogStream`, `PutLogEvents` | Solo su grupo de logs. El `:*` final cubre cada flujo de logs, uno por contenedor |

No hay ni un `*`. Si el código tuviera un fallo o alguien lo manipulara, lo peor que podría
hacer es leer esta cola y publicar en este topic.

Los permisos de SQS no los usa el Python, sino el **event source mapping**, que trabaja con el
rol de la función. Se explica en
[EVENT-SOURCE-MAPPING](EVENT-SOURCE-MAPPING.md#4-con-qué-permisos-habla-el-portero-con-la-cola).

### 7.5 La función

| Ajuste | Valor | Por qué |
|---|---|---|
| `runtime` | `python3.13` | La misma versión que en local |
| `handler` | `manejador.handler` | "fichero.función" |
| `architectures` | `arm64` | Procesadores Graviton de AWS: en torno a un **20 % más baratos** que x86. Posible porque el código es Python puro |
| `memory_size` | `256` | Fue 128 MB con el léxico, que usaba 93. Con los SDK de la IA sube a unos 145 MB. En Lambda la memoria también reparte la CPU ([IA](IA.md#13-el-arranque-en-frío-medido-pendiente-de-decidir)) |
| `timeout` | `120` | Fue 30 s con el léxico. Está **atado a la cola**: el visibility timeout es 6 × 120 = 720 s, como recomienda AWS. Si se cambia uno, hay que cambiar el otro |
| `layers` | La capa de dependencias | Los SDK de Anthropic y OpenAI, compilados para Linux ARM (Fase 7) |
| `source_code_hash` | La huella del `.zip` | Si cambia una letra del Python, cambia la huella y Terraform sube el código nuevo |
| `environment` | `TOPIC_ARN`, `PROVEEDOR_ANALISIS`, `MODELO`, `SECRETO_ID` | Adónde publicar y quién analiza. Del secreto solo viaja el **nombre**, nunca la clave |

### 7.6 La conexión con la cola

| Ajuste | Valor |
|---|---|
| `batch_size` | 5 mensajes por invocación, como máximo. Fueron 10 con el léxico; con la IA, cada reseña puede tardar hasta 20 s |
| `enabled` | `var.flujo_activo`: el interruptor general también corta aquí |
| `function_response_types` | `ReportBatchItemFailures`: activa la respuesta parcial |
| `maximum_concurrency` | 2 copias a la vez, como mucho |
| `depends_on` | Los permisos: al crear la conexión, AWS comprueba en ese momento que el rol ya puede leer la cola |

Cómo funciona esta pieza por dentro es el tema de
[EVENT-SOURCE-MAPPING](EVENT-SOURCE-MAPPING.md).

## 8. El límite de 10 de la cuenta

Lo normal para poner un tope a una función es la **concurrencia reservada**. En esta cuenta es
imposible: su límite total es de **10 ejecuciones simultáneas**, cuando una cuenta normal tiene
1000, y AWS exige dejar siempre 10 sin reservar. Reservar aunque sea 1 dejaría 9, y AWS lo
rechaza.

Por eso el freno está en la conexión con la cola: `maximum_concurrency = 2` no reserva nada,
solo impide que la cola dispare más de 2 copias a la vez. El mínimo que admite AWS es
precisamente 2.

## 9. Cambios en el apagado

- `flujo_activo = false` corta ahora **dos** cosas: la regla y el consumo de la cola.
- El apagado nocturno **solo** deshabilita la regla y deja que la Lambda termine lo pendiente.

Se explica en [INFRAESTRUCTURA](INFRAESTRUCTURA.md#9-apagadotf-el-freno-de-mano).

## 10. Coste

| Servicio | Uso | Coste |
|---|---|---|
| Lambda | ~2 s × 256 MB por invocación en caliente, con 1 millón de invocaciones y 400.000 GB-s al mes gratis | $0 |
| OpenAI `gpt-5.6-luna` (Fase 7) | ~380 tokens de entrada y ~60 de salida por reseña | ~0,15 $ por cada 1.000 reseñas |
| Secrets Manager (Fase 7) | 1 secreto | 0,40 $/mes |
| CloudWatch Logs | Una línea por reseña, durante 7 días | $0 |
| SNS por correo | 1.000 notificaciones al mes gratis | $0 |

## 11. Ver lo que hace

```powershell
aws logs tail /aws/lambda/workingevents-analizador --follow --region eu-west-1
```

Cada reseña deja una línea JSON con su identificador, el del evento, la calificación, la
puntuación, el sentimiento, si hubo alerta y el motivo. En CloudWatch se puede filtrar por
cualquiera de esos campos.
