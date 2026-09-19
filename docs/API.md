# La API en .NET 10

La API que recibe las reseñas y las publica en EventBridge. Código en
[`src/api/`](../src/api/).

---

## 1. Resultado

| Petición | Respuesta | ¿Llegó a la cola? |
|---|---|---|
| Inválida (`calificacion: 9`, correo mal escrito) | **400** con tres errores | No: ni siquiera se llama a AWS |
| Negativa, 2 estrellas | **202** con su `eventId` | ✅ Sí |
| Positiva, 5 estrellas | **202** con su `eventId` | ❌ No: la regla la descartó |

Es el mismo comportamiento de la [prueba manual](PRUEBA-MANUAL.md), pero con el evento generado
por el código.

## 2. Qué crea `dotnet new web`

`dotnet` es el programa de .NET, `new` crea un proyecto a partir de una plantilla, y `web` es la
plantilla más vacía que existe para una API. Se eligió para que todo lo que hay dentro se haya
escrito a propósito.

| Fichero | Qué es |
|---|---|
| `WorkingEvents.Api.csproj` | La **ficha del proyecto**: versión de .NET y librerías que necesita |
| `Program.cs` | El **punto de entrada**: lo primero que se ejecuta al arrancar |
| `appsettings.json` | **Configuración** como datos, que se puede cambiar sin recompilar |
| `Properties/launchSettings.json` | Cómo arrancar **en local**: puerto y variables de entorno |

## 3. NuGet y el SDK de AWS

.NET no sabe hablar con AWS por sí solo. Esa capacidad la añade una librería.

- **NuGet** es el almacén público de librerías de .NET.
- `dotnet add package AWSSDK.EventBridge` añade al `.csproj` la línea
  `<PackageReference Include="AWSSDK.EventBridge" Version="4.0.100.14" />`.
- Un **SDK** (*Software Development Kit*) hace de puente entre un lenguaje y un servicio.
  Convierte los trámites de la ventanilla de EventBridge en métodos de C#: en lugar de construir
  a mano una petición HTTPS firmada, se llama a `PutEventsAsync(...)`.

Hay un paquete por servicio, y solo se instala el que hace falta.

## 4. El recorrido de una petición

```
Cliente
   │  POST /resenyas   {"comentario":..., "calificacion":2, "email":...}
   ▼
① .NET convierte el JSON en un objeto NuevaResenya
② Validación: ¿se cumplen [Required], [Range] y [EmailAddress]?
   │   NO → responde 400 y se para aquí. AWS no se entera
   ▼ SÍ
③ El endpoint crea un ResenyaEnviada y le asigna un Id
④ PublicadorDeEventos rellena el formulario de PutEvents
⑤ El SDK firma la petición y la envía a EventBridge
⑥ EventBridge responde: aceptado (EventId) o rechazado (ErrorCode)
⑦ La API responde 202 con los dos identificadores, o 502 si hubo rechazo
```

## 5. `NuevaResenya`: lo que entra

```csharp
public sealed record NuevaResenya
{
    [Required(ErrorMessage = "Escribe un comentario.")]
    [StringLength(2000, MinimumLength = 3, ErrorMessage = "El comentario debe tener entre 3 y 2000 caracteres.")]
    public string Comentario { get; init; } = "";

    [Range(1, 5, ErrorMessage = "Elige una valoración de 1 a 5 estrellas.")]
    public int Calificacion { get; init; }

    [Required(ErrorMessage = "Escribe tu correo.")]
    [EmailAddress(ErrorMessage = "Ese correo no parece válido.")]
    public string Email { get; init; } = "";
}
```

Los `ErrorMessage` se añadieron en la Fase 5. Sin ellos, .NET usa sus textos por defecto, en
inglés, y el formulario los mostraba así en una página en español
([FRONTAL](FRONTAL.md#8-dos-validaciones-con-papeles-distintos)).

| Palabra | Significado |
|---|---|
| `record` | Un tipo pensado para **transportar datos**. Dos records con los mismos valores son iguales |
| `sealed` | Nadie puede heredar de él |
| `{ get; init; }` | Se puede leer siempre, pero solo se asigna **al crear** el objeto |
| `= ""` | Valor inicial si el JSON no trae el campo |

| Atributo | Regla |
|---|---|
| `[Required]` | No puede faltar ni estar vacío |
| `[StringLength(2000, MinimumLength = 3)]` | Entre 3 y 2000 caracteres |
| `[Range(1, 5)]` | Número entre 1 y 5 |
| `[EmailAddress]` | Tiene que tener forma de correo |

- **No lleva `Id`:** lo pone el servidor. Si lo eligiera el cliente, dos clientes podrían mandar
  el mismo, o alguien podría reutilizar a propósito el de una reseña ajena.
- **`[Range(1, 5)]` es crucial:** un `int` que no llega en el JSON vale 0. Sin esta regla, una
  petición sin calificación se publicaría como una reseña de 0 estrellas y generaría una alerta
  falsa.

## 6. `ResenyaEnviada`: lo que sale

```csharp
public sealed record ResenyaEnviada(string Id, string Comentario, int Calificacion, string Email);
```

Son dos tipos distintos porque son contratos con interlocutores distintos:

| | `NuevaResenya` | `ResenyaEnviada` |
|---|---|---|
| Contrato con | El formulario web | La regla de EventBridge y la Lambda |
| Lleva `Id` | No | Sí |
| Si se cambia un nombre | El formulario recibe un 400 **visible** | La regla deja de encajar **en silencio** |

Esa última fila es la importante. Si se renombra `Calificacion`, **no hay error de compilación
en ningún sitio**: los eventos se siguen publicando, la regla ya no los reconoce y se descartan
sin dejar rastro.

## 7. La configuración

```json
"Eventos": {
  "Region": "eu-west-1",
  "Bus":    "workingevents-bus",
  "Source": "workingevents.api"
}
```

Son datos del entorno, no lógica: si mañana existe un bus de producción, se cambia este fichero
sin recompilar. **Nada de esto es secreto**: son nombres. Las credenciales no están en ningún
fichero del proyecto.

`OpcionesEventos.Validar()` se ejecuta **al arrancar**. Si falta un valor, la API se niega a
arrancar con un mensaje claro. Lo contrario sería arrancar sin problemas y fallar con la
primera reseña.

## 8. `PublicadorDeEventos`: el mismo formulario, en C#

| Campo | Prueba manual (CLI) | La API (C#) |
|---|---|---|
| `Source` | escrito en `eventos.json` | `opciones.Source`, de `appsettings.json` |
| `DetailType` | escrito a mano | `nameof(ResenyaEnviada)` |
| `EventBusName` | escrito en `eventos.json` | `opciones.Bus` |
| `Detail` | `json.dumps(...)` en Python | `JsonSerializer.Serialize(evento, Json)` |
| La llamada | `aws events put-events` | `eventBridge.PutEventsAsync(...)` |
| Las credenciales | `AWS_PROFILE` en la terminal | `AWS_PROFILE` en `launchSettings.json` |

Cambia la puerta, no el trámite. `nameof(ResenyaEnviada)` devuelve el texto
`"ResenyaEnviada"`, así el `DetailType` y el nombre de la clase no se pueden desalinear por una
errata. La contrapartida es que renombrar la clase cambia el `DetailType`.

### Trampa 1: las mayúsculas del JSON

```csharp
private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
```

En C# la propiedad se llama `Calificacion`, y el serializador por defecto escribiría
`{"Calificacion": 2}`. La regla busca `calificacion`, y **EventBridge distingue mayúsculas de
minúsculas**. `JsonSerializerDefaults.Web` escribe los nombres en *camelCase*:
`{"calificacion": 2}`.

Sin esta línea, **ninguna reseña encajaría nunca** y no habría un solo error en ningún sitio.

### Trampa 2: `PutEvents` no lanza excepciones

```csharp
if ((respuesta.FailedEntryCount ?? 0) > 0 || string.IsNullOrEmpty(resultado?.EventId))
```

Normalmente, en C# un fallo lanza una **excepción** que no se puede pasar por alto. `PutEvents`
no funciona así: si rechaza un evento, **responde con éxito** y anota el rechazo en
`FailedEntryCount`. Si no se comprueba, el cliente recibe un 202 y el evento se ha perdido.

| Símbolo | Significado |
|---|---|
| `?? 0` | "Si no tiene valor, usa 0". En la versión 4 del SDK, `FailedEntryCount` puede venir vacío |
| `resultado?.EventId` | "Si `resultado` existe, dame su `EventId`; si no, nada" |
| `\|\|` | "O": basta con que se cumpla una de las dos condiciones |

### `async` y "asíncrono" no son lo mismo

- **`async`/`await` en C#:** mientras espera la respuesta de AWS, unas decenas de
  milisegundos, el servidor puede atender otras peticiones.
- **Asíncrono en la arquitectura:** la API **no espera** a que se analice la reseña. Solo espera
  a que EventBridge diga "recibido".

## 9. `Program.cs`

### 9.1 La inyección de dependencias

El endpoint pide un `PublicadorDeEventos`, pero nunca se escribe
`new PublicadorDeEventos(...)`. La analogía: un cocinero pide un cuchillo y el encargado del
almacén se lo da; el cocinero no fabrica el cuchillo ni sabe dónde se guarda. El almacén es
`builder.Services`, y **registrar** una pieza es dejarle las instrucciones para fabricarla.

| Parámetro del endpoint | De dónde sale |
|---|---|
| `NuevaResenya peticion` | Del **cuerpo JSON** de la petición |
| `PublicadorDeEventos publicador` | Del **almacén**, porque está registrado |
| `CancellationToken ct` | Se activa si el cliente corta la conexión, para no seguir trabajando para nadie |

**`Singleton`** significa que se fabrica **una sola vez** y se comparte. Es lo correcto para el
cliente de AWS, que mantiene abiertas las conexiones HTTPS.

### 9.2 Las credenciales: en el código no hay ninguna

El SDK busca las credenciales solo, **en este orden**, y usa las primeras que encuentra:

| Orden | Dónde busca | Cuándo aplica |
|---|---|---|
| 1 | Variables de entorno con claves (`AWS_ACCESS_KEY_ID`…) | **Dentro de Lambda** (ver abajo) |
| 2 | El perfil que indique `AWS_PROFILE` | **En local**: lo pone `launchSettings.json` |
| 3 | El perfil `default` | — |
| 4 | El rol del contenedor, si corre en ECS | En la Fase 8, si la API se despliega en ECS |

Dentro de Lambda, el servicio obtiene las credenciales **temporales** del rol de la función y
las mete en variables de entorno (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y
`AWS_SESSION_TOKEN`) antes de ejecutar el código. Por eso el log de la Lambda dice
`Found credentials in environment variables`: las encuentra en el punto 1. Se comprobó en
la [prueba de punta a punta](PRUEBA-DE-PUNTA-A-PUNTA.md#9-lo-que-la-prueba-corrigió).

La consecuencia importante: **este código no cambiará al desplegarse**. Solo cambia de dónde
salen las credenciales.

### 9.3 Validación y errores

- `AddValidation()`, nuevo en .NET 10, es lo que hace cumplir los atributos de `NuevaResenya`.
  Sin él, `[Range]` y `[Required]` serían decoración.
- `AddProblemDetails()` da a todos los errores el formato JSON estándar RFC 9457 (`type`,
  `title`, `status`, `errors`…).

### 9.4 CORS

Desde la Fase 5, `Program.cs` autoriza a ciertas páginas de otro origen a llamar a la API desde
un navegador. La lista de orígenes sale de la configuración: vacía en `appsettings.json`, y con
`http://localhost:3000` en `appsettings.Development.json`. Se explica en
[FRONTAL](FRONTAL.md#9-cors-desde-cero).

### 9.5 El endpoint y los códigos HTTP

`Guid.NewGuid()` genera un identificador que en la práctica nunca se repite. El prefijo `rev-`
lo hace reconocible en los logs, y `.Trim()` quita los espacios del principio y del final.

| Código | Cuándo | Significado |
|---|---|---|
| **202 Accepted** | EventBridge aceptó el evento | "Recibido, se procesará después". Es exactamente lo que pasa |
| 200 OK | No se usa | Significaría "hecho", y sería falso: el análisis aún no ha ocurrido |
| **400 Bad Request** | Falla la validación | El error es del cliente |
| **502 Bad Gateway** | EventBridge rechazó el evento | El error es de un servicio del que depende la API, no del cliente |

## 10. `launchSettings.json`

- **Puerto fijo 5080**, en lugar del aleatorio de la plantilla.
- **`AWS_PROFILE` ya viene puesto.** .NET define la variable solo para ese proceso, así que no
  hace falta el `$env:AWS_PROFILE` de PowerShell. Se comprobó arrancando la API con la variable
  borrada de la terminal. Si clonas el repositorio, **cambia el nombre del perfil** por el tuyo.

La diferencia entre este fichero y `appsettings.json`, quién lee cada uno y qué lo sustituirá
cuando la API se despliegue en AWS se explica a fondo en [CONFIGURACION-API](CONFIGURACION-API.md).

El fichero [`WorkingEvents.Api.http`](../src/api/WorkingEvents.Api.http) tiene las peticiones de
prueba. Visual Studio y VS Code, este con la extensión REST Client, muestran encima de cada una
un botón **Send Request**.

## 11. Dos identificadores, dos papeles

La API responde `{"id":"rev-b0da099c-…","eventId":"67d53897-…"}`:

| | `id` (`rev-…`) | `eventId` |
|---|---|---|
| Quién lo pone | La API | EventBridge |
| Identifica | **La reseña** | **Este envío de la noticia** |
| Dónde aparece | Dentro de `detail` | En el sobre |
| Para qué | Hablar de la reseña con el negocio | Seguir el evento por la infraestructura |

Con la analogía de Correos: el `id` es el número de pedido escrito en la carta, y el `eventId`
el número de seguimiento que pone Correos en el sobre.

## 12. Lo que todavía no hace

- ~~CORS~~: resuelto en la Fase 5, ver [FRONTAL](FRONTAL.md#9-cors-desde-cero).
- **Autenticación y límite de peticiones:** cualquiera que llegue a la API puede publicar sin
  límite. Es el riesgo que cubre `flujo_activo`. En local no importa; antes de la Fase 8, sí.
- **Pruebas automáticas.**

## 13. Arrancarla

```powershell
dotnet run --project src/api
```

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:5080/resenyas -ContentType 'application/json' -Body '{"comentario":"Llegó roto y nadie responde","calificacion":1,"email":"prueba@ejemplo.com"}'
```
