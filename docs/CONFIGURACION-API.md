# Configuración de la API: `appsettings.json`, `launchSettings.json` y su sustitución en AWS

**Proyecto:** WorkingEvents · **Fecha:** 2026-09-19

**Índice**

- Parte 1. Diferencia entre `appsettings.json` y `launchSettings.json`
- Parte 2. Cómo la task definition de ECS sustituirá a `launchSettings.json` (Fase 8)

---

## Parte 1. Diferencia entre `appsettings.json` y `launchSettings.json`

Los ficheros se citan tal como quedaron en la Fase 3.

### 1. La diferencia principal

- **`appsettings.json` lo lee tu aplicación.** Contiene lo que la API necesita saber para funcionar, esté donde esté.
- **`launchSettings.json` lo lee la herramienta que arranca la aplicación** (`dotnet run` o Visual Studio). Dice cómo arrancarla **en tu máquina**. Tu código nunca lo abre.

| | `appsettings.json` | `launchSettings.json` |
|---|---|---|
| Quién lo lee | La API, al arrancar | `dotnet run` / Visual Studio, **antes** de arrancar la API |
| Qué contiene | Datos que usa el código: bus, región, logs | Cómo lanzarla: puerto, variables de entorno |
| Dónde vale | En tu PC **y** en AWS | Solo en tu PC |
| ¿Viaja con la app al publicarla? | Sí | No |

### 2. Una analogía

Piensa en una obra de teatro en la que la API es el actor:

- `appsettings.json` es **el guion**. El actor lo lee y se lo lleva a cada teatro de la gira.
- `launchSettings.json` son **las notas del regidor** de tu teatro local: qué escenario usar y qué luces encender antes de que salga el actor. El actor nunca las lee; cuando sale, el escenario ya está listo.
- Cuando la obra salga de gira (la Fase 8, desplegar en AWS), el guion viaja y las notas del regidor se quedan en casa. En el nuevo teatro habrá otro regidor con sus propias notas: la definición de la tarea de ECS.

### 3. `appsettings.json`, clave por clave

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "AllowedHosts": "*",
  "Eventos": {
    "Region": "eu-west-1",
    "Bus": "workingevents-bus",
    "Source": "workingevents.api"
  }
}
```

| Clave | Qué hace |
|---|---|
| `Logging:LogLevel:Default` = `Information` | Qué mensajes de log se muestran: los de nivel `Information` y los más graves. Los de depuración no |
| `Logging:LogLevel:Microsoft.AspNetCore` = `Warning` | Para el funcionamiento interno del framework, solo avisos y errores. Si no, cada petición llenaría la consola de líneas internas |
| `AllowedHosts` = `*` | Qué nombres de servidor acepta la API en la cabecera `Host` de las peticiones. `*` significa cualquiera. Viene de la plantilla |
| `Eventos` | **Nuestra** sección. `Program.cs` la lee con `GetSection("Eventos").Get<OpcionesEventos>()` y la convierte en el objeto que usa el publicador |

.NET usa las dos primeras por su cuenta. `Eventos` solo existe porque nuestro código la pide.

### 4. `launchSettings.json`, clave por clave

```json
{
  "$schema": "https://json.schemastore.org/launchsettings.json",
  "profiles": {
    "http": {
      "commandName": "Project",
      "dotnetRunMessages": true,
      "launchBrowser": false,
      "applicationUrl": "http://localhost:5080",
      "environmentVariables": {
        "ASPNETCORE_ENVIRONMENT": "Development",
        "AWS_PROFILE": "testenforce-b"
      }
    }
  }
}
```

| Clave | Qué hace |
|---|---|
| `$schema` | Solo sirve al editor: le dice qué claves son válidas para que te las autocomplete. No afecta a la ejecución |
| `profiles` | La lista de **formas de arrancar**. Podría haber varias (con HTTPS, con Docker…). Aquí hay una, llamada `http`. En Visual Studio aparecen en el desplegable junto al botón ▶ |
| `commandName: "Project"` | Arranca el proyecto directamente con **Kestrel**, el servidor web que viene con .NET. Otras opciones serían `IISExpress` o `Docker` |
| `dotnetRunMessages: true` | `dotnet run` muestra mensajes como "Compilando…" mientras prepara |
| `launchBrowser: false` | No abre el navegador, porque una API no tiene página que enseñar |
| `applicationUrl` | La dirección y el puerto en que escucha: `http://localhost:5080` |
| `environmentVariables` | Variables de entorno que se crean **solo para el proceso de la API**. No tocan tu terminal ni el resto de Windows |

Las dos variables:

- **`ASPNETCORE_ENVIRONMENT = Development`** le dice a .NET "estás en desarrollo". Con eso decide, entre otras cosas, si carga un `appsettings.Development.json`. Ese fichero lo borré, así que ahora no se carga nada extra.
- **`AWS_PROFILE = testenforce-b`** no la lee tu código, sino **el SDK de AWS**. Es el paso 2 de la búsqueda de credenciales que vimos: "usa las claves del perfil testenforce-b".

### 5. Cómo se demuestra que la API no lee `launchSettings.json`

**a) Lo que ya pasó en la Fase 3.** Antes de arrancar la API borré a propósito `AWS_PROFILE` de mi terminal (`unset AWS_PROFILE`), y aun así se autenticó bien. Fue `dotnet run` quien leyó `launchSettings.json` y creó la variable para el proceso de la API.

**b) Lo que pasaría si ejecutaras el programa compilado directamente**, sin `dotnet run`:

```powershell
.\src\api\bin\Debug\net10.0\WorkingEvents.Api.exe
```

Nadie leería `launchSettings.json`, y entonces:

- La API escucharía en el puerto por defecto de Kestrel, `http://localhost:5000`, no en el 5080.
- No existiría `AWS_PROFILE`, y el SDK pasaría al perfil `default`. Según lo que tenga ese perfil, fallaría por falta de credenciales o usaría otras que no son las del proyecto.

`appsettings.json`, en cambio, seguiría funcionando: al compilar se copia al lado del `.exe` y la API lo lee sola.

### 6. Cómo se relacionan: las variables de entorno tienen prioridad

Los dos ficheros no son del todo independientes. Al arrancar, `WebApplication.CreateBuilder` junta la configuración de varias fuentes en este orden. **Si una misma clave aparece en dos fuentes, gana la que está más abajo:**

| Orden | Fuente | En este proyecto |
|---|---|---|
| 1 | `appsettings.json` | `Eventos:Bus = workingevents-bus` |
| 2 | `appsettings.{Entorno}.json` | No existe (lo borré) |
| 3 | User secrets (solo en Development) | No los usamos |
| 4 | **Variables de entorno** | Aquí entran las de `launchSettings.json` |
| 5 | Argumentos de la línea de comandos | No los usamos |

Así que `launchSettings.json` puede **sobrescribir** valores de `appsettings.json` mediante variables de entorno. En el nombre de la variable, los dos puntos de la jerarquía se escriben con doble guion bajo. Por ejemplo, si añadieras esto a `environmentVariables`:

```json
"Eventos__Bus": "otro-bus"
```

la API publicaría en `otro-bus` sin tocar `appsettings.json`. No lo hemos hecho; solo es para que veas el mecanismo. Es justo como se configura una aplicación en AWS: `appsettings.json` lleva los valores por defecto y el entorno los ajusta.

### 7. Cómo decidir dónde va cada cosa

Hazte dos preguntas:

1. **¿La aplicación lo necesita en cualquier sitio donde se ejecute?** → `appsettings.json`
2. **¿Solo sirve para arrancarla en mi máquina, o depende de mi máquina?** → `launchSettings.json`

Aplicado a lo que tenemos:

| Valor | Dónde está | Por qué |
|---|---|---|
| `Bus`, `Region`, `Source` | `appsettings.json` | La API también los necesita en AWS. Si solo estuvieran en `launchSettings.json`, al desplegarla `Validar()` detendría el arranque por configuración incompleta |
| Puerto `5080` | `launchSettings.json` | En AWS el puerto lo decide el contenedor |
| `AWS_PROFILE` | `launchSettings.json` | En AWS **no debe haber perfil**: el SDK tiene que usar el rol del contenedor. Si este valor viajara con la app, allí buscaría un perfil que no existe |

Y una tercera regla: **los secretos no van en ninguno de los dos**, porque los dos ficheros acabarán en git (el `.gitignore` no los excluye). `testenforce-b` no es un secreto, es un nombre; las claves de verdad están en `~/.aws/credentials`, fuera del proyecto. Cuando llegue la API key de Anthropic en la Fase 7, irá a Secrets Manager.

### Qué pasa cuando ejecutas `dotnet run`, en orden

1. `dotnet run` busca `Properties/launchSettings.json` y elige el primer perfil de tipo `Project`, que es `http`.
2. Compila el proyecto; son los mensajes que activa `dotnetRunMessages`.
3. Lanza el proceso de la API con tres variables de entorno: `ASPNETCORE_ENVIRONMENT=Development`, `AWS_PROFILE=testenforce-b` y `ASPNETCORE_URLS=http://localhost:5080`, que sale de `applicationUrl`.
4. La API arranca y `CreateBuilder` lee primero `appsettings.json` y después las variables de entorno, y lo junta todo.
5. `Program.cs` lee la sección `Eventos` y la valida.
6. Kestrel se queda escuchando en el puerto 5080.
7. Con la primera reseña, el SDK busca credenciales, encuentra `AWS_PROFILE` y firma la petición con `testenforce-b`.

---

## Parte 2. Cómo la task definition de ECS sustituirá a `launchSettings.json` (Fase 8)

Una aclaración antes de empezar: la Fase 8 todavía no está decidida. Te lo explico suponiendo **ECS Fargate**, que es lo que ya usaste en TestEnforce. Los fragmentos de Terraform de abajo son un **boceto** de lo que escribiríamos, no algo que ya exista en el proyecto.

### 1. Las piezas nuevas, desde cero

Para ejecutar la API en AWS aparecen cinco conceptos:

| Pieza | Qué es | En la analogía del teatro |
|---|---|---|
| **Imagen** (Docker) | Un paquete que contiene la API compilada y todo lo que necesita para arrancar. Se construye una vez y se ejecuta igual en cualquier sitio | El actor, que lleva el guion en la maleta |
| **ECR** | El almacén de imágenes de AWS | El camerino donde espera el actor |
| **Task definition** (definición de tarea) | Una ficha que dice **cómo** arrancar la imagen: qué variables de entorno, qué puerto, cuánta memoria y con qué permisos | **Las notas del regidor del nuevo teatro** |
| **Fargate** | El modo de ECS en el que AWS pone la máquina y tú no gestionas ningún servidor | El teatro alquilado con el personal incluido |
| **Service** (servicio) | Lo que mantiene encendidas N copias de la tarea y levanta otra si una se cae | El director de gira, que se asegura de que siempre haya función |

La idea clave: **la task definition hace en AWS el mismo papel que `launchSettings.json` en tu PC.** Ninguno de los dos lo lee tu código; los dos preparan el entorno antes de que arranque la API.

### 2. `launchSettings.json` no llega a la nube

Esto no es solo una convención, es algo físico. Para crear la imagen se usa `dotnet publish`, que genera la versión lista para distribuir de la API. Lo que incluye es esto:

| Fichero | ¿Entra en la imagen? |
|---|---|
| `WorkingEvents.Api.dll` (tu código compilado) | ✅ |
| `appsettings.json` | ✅ se copia junto a la dll |
| `Properties/launchSettings.json` | ❌ **`dotnet publish` lo excluye** |

Dentro del contenedor ese fichero no existe. Por eso lo que hacía tiene que venir de otro sitio, y ese sitio es la task definition.

### 3. Cómo se sustituye cada línea

| En `launchSettings.json` | En AWS | Por qué |
|---|---|---|
| `commandName: "Project"` | El `ENTRYPOINT` del Dockerfile: `dotnet WorkingEvents.Api.dll` | En local, `dotnet run` compila y arranca. En la nube ya está compilado; solo se arranca |
| `dotnetRunMessages`, `launchBrowser`, `$schema` | **Nada** | En la nube no se compila y no hay navegador |
| `applicationUrl: http://localhost:5080` | `portMappings` → puerto **8080** | Ver punto 4 |
| `ASPNETCORE_ENVIRONMENT: Development` | `environment` → `Production` | En la nube no estás desarrollando |
| `AWS_PROFILE: testenforce-b` | **Desaparece.** Lo sustituye `task_role_arn` | Es el cambio más importante. Ver puntos 5 y 6 |
| *(no existe en local)* | `cpu`, `memory` | En tu PC la API usa lo que haya libre. En Fargate pagas por lo que reservas |
| *(no existe en local)* | `logConfiguration` | En local los logs salen por la consola. En la nube nadie mira la consola, así que se envían a CloudWatch |

### 4. Por qué `localhost` no sirve dentro de un contenedor

`localhost` significa "esta misma máquina". Dentro de un contenedor, "esta misma máquina" es **solo el contenedor**.

Si la API escuchara en `localhost:5080` dentro del contenedor, solo aceptaría conexiones que salieran del propio contenedor. Es como hablar solo en una habitación cerrada: te oyes tú, pero nadie de fuera. Las peticiones de fuera llegan por la interfaz de red del contenedor, no por `localhost`, y nunca la encontrarían.

Las imágenes oficiales de .NET (desde .NET 8) ya lo resuelven: traen puesta la variable `ASPNETCORE_HTTP_PORTS=8080`, que hace que la API escuche en el puerto 8080 **por todas las interfaces**. Por eso en la task definition el puerto es el 8080 y no el 5080.

### 5. Adiós a `AWS_PROFILE`: cómo encuentra el SDK las credenciales en la nube

Es el mismo orden de búsqueda de la Fase 3, pero ahora recorrido dentro del contenedor:

| Orden | Dónde busca el SDK | Dentro del contenedor |
|---|---|---|
| 1 | Variables con claves (`AWS_ACCESS_KEY_ID`…) | No hay → siguiente |
| 2 | El perfil de `AWS_PROFILE` | No hay variable → siguiente |
| 3 | El perfil `default` | No existe la carpeta `~/.aws/` → siguiente |
| 4 | **Credenciales del contenedor** | ✅ **Las encuentra aquí** |

¿Cómo funciona el paso 4? Al arrancar la tarea, ECS crea **por su cuenta** una variable de entorno llamada `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`. Ni tú ni la task definition la escribís. El SDK la ve y pregunta a una dirección interna de AWS: "¿qué credenciales tengo?". AWS le responde con **credenciales temporales** del **rol de la tarea**, que caducan y se renuevan solas.

La analogía: en tu PC, la API enseña **una llave maestra que es tuya** (las claves de `testenforce-b`, guardadas en tu disco y sin caducidad). En AWS, la API recibe en la puerta **un pase de visitante que caduca en unas horas**, y nadie tiene que guardarlo en ningún fichero.

**Tu código no cambia ni una línea.** El `new AmazonEventBridgeClient(...)` de `Program.cs` es el mismo; lo único que cambia es dónde termina la búsqueda.

### 6. Dos roles distintos: uno para el regidor y otro para el actor

Esto confunde a casi todo el mundo la primera vez. La task definition lleva **dos** roles de IAM:

| | **Rol de ejecución** (`execution_role_arn`) | **Rol de la tarea** (`task_role_arn`) |
|---|---|---|
| Quién lo usa | **ECS**, antes de que arranque tu API | **Tu código**, mientras se ejecuta |
| Para qué | Descargar la imagen de ECR y enviar los logs a CloudWatch | Llamar a `PutEvents` en el bus |
| En la analogía | El regidor, que necesita llaves del camerino y del cuarto de luces | El actor, que necesita permiso para salir al escenario |
| Qué permisos | La política gestionada `AmazonECSTaskExecutionRolePolicy` | **Solo** `events:PutEvents` sobre **tu** bus |

El **rol de la tarea** es el que sustituye de verdad a `AWS_PROFILE`, y aquí aparece una diferencia que conviene conocer:

| | En tu PC hoy | En AWS en la Fase 8 |
|---|---|---|
| Identidad | El usuario IAM del perfil `testenforce-b` | Rol de la tarea |
| Permisos | **`AdministratorAccess`**: puede hacer cualquier cosa en la cuenta | Solo publicar en `workingevents-bus` |

En local tu API tiene muchísimo más poder del que necesita. En la nube tendrá exactamente el mínimo. Si alguien encontrara un fallo en la API, en AWS solo podría publicar reseñas falsas, no borrar la cuenta.

### 7. El boceto en Terraform

**El permiso de la tarea**: el equivalente a lo que te daba `testenforce-b`, pero reducido al mínimo:

```hcl
# Quien puede "ponerse" este rol: solo las tareas de ECS.
data "aws_iam_policy_document" "confianza_tarea" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Que puede hacer: publicar en ESTE bus, y nada mas.
data "aws_iam_policy_document" "api_publica" {
  statement {
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.principal.arn]
  }
}
```

**La task definition**: las notas del regidor. Fíjate en los comentarios que la relacionan con `launchSettings.json`:

```hcl
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256 # 0,25 vCPU
  memory                   = 512 # MB

  execution_role_arn = aws_iam_role.ejecucion_api.arn # el regidor
  task_role_arn      = aws_iam_role.tarea_api.arn     # el actor: SUSTITUYE a AWS_PROFILE

  container_definitions = jsonencode([{
    name      = "api"
    image     = "${aws_ecr_repository.api.repository_url}:${var.version_api}"
    essential = true

    # Sustituye a applicationUrl. 8080 y no 5080: ver punto 4.
    portMappings = [{ containerPort = 8080 }]

    # Sustituye a environmentVariables.
    environment = [
      { name = "ASPNETCORE_ENVIRONMENT", value = "Production" },
      # AWS_PROFILE no aparece, a proposito. Si apareciera, el SDK buscaria
      # un perfil que en el contenedor no existe y fallaria.
    ]

    # No existe en local: aqui nadie mira la consola.
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "api"
      }
    }
  }])
}
```

Un detalle sobre `ASPNETCORE_ENVIRONMENT`: si no se pone, .NET supone `Production` por defecto. Escribirla es redundante, pero deja claro qué entorno es sin tener que conocer esa regla.

### 8. Lo que NO cambia

| Fichero | ¿Cambia en la Fase 8? |
|---|---|
| `Program.cs` | No |
| `PublicadorDeEventos.cs` | No |
| `appsettings.json` | No: viaja dentro de la imagen tal cual |
| `launchSettings.json` | No: sigue sirviendo para tu PC y la nube lo ignora |

Es el resultado de haber separado bien los dos ficheros en la Fase 3.

Y el mecanismo de sobrescritura de la sección 6 de la Parte 1 funciona igual aquí. Si algún día hubiera un bus de producción, bastaría con añadir en `environment`:

```hcl
{ name = "Eventos__Bus", value = "workingevents-bus-prod" },
```

sin reconstruir la imagen ni tocar `appsettings.json`.

### 9. Lo que la Fase 8 traerá además

Para que no parezca más sencillo de lo que es:

- **Coste por horas.** Es el primer recurso del proyecto que cobra por estar encendido. Una tarea pequeña encendida todo el día ronda los **9 $/mes**, según la cifra que ya tienes anotada en TestEnforce para una tarea de ECS. Aquí es donde `apagado_nocturno = true` empieza a tener sentido, con una cita programada que ponga el servicio a cero tareas, como en TestEnforce.
- **Llegar desde fuera.** Para que el navegador alcance la API hará falta un balanceador o una IP pública, y eso tiene su propio coste y sus propias decisiones.
- **Alternativas.** App Runner es más sencillo (sin balanceador ni task definition que escribir), y tiene su propio "rol de instancia" que cumple el mismo papel que el rol de la tarea. Lo compararemos cuando lleguemos.

### Qué pasará en la Fase 8, en orden

1. **Dockerfile:** la receta de la imagen, con `dotnet publish` dentro.
2. **`docker build`:** se crea la imagen. Lleva `appsettings.json` y **no** lleva `launchSettings.json`.
3. **`docker push`:** la imagen sube a ECR.
4. **Terraform:** los dos roles, la task definition y el servicio.
5. **ECS arranca la tarea.** Con el rol de ejecución descarga la imagen, crea las variables de entorno de la task definition y añade por su cuenta `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`.
6. **La API arranca.** `CreateBuilder` lee `appsettings.json` y después las variables de entorno. Kestrel escucha en el 8080.
7. **Llega la primera reseña.** El SDK falla en los pasos 1, 2 y 3 de la búsqueda, encuentra las credenciales del contenedor en el 4 y firma `PutEvents` con un pase temporal del rol de la tarea.
8. **El mensaje llega a la cola**, exactamente igual que en la prueba de la Fase 3.