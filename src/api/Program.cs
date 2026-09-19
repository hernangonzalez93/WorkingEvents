using Amazon;
using Amazon.EventBridge;
using WorkingEvents.Api.Eventos;
using WorkingEvents.Api.Resenyas;

var builder = WebApplication.CreateBuilder(args);

// ---------------------------------------------------------------------------
// 1. A que bus publicar
// ---------------------------------------------------------------------------
var opciones = builder.Configuration.GetSection("Eventos").Get<OpcionesEventos>()
    ?? throw new InvalidOperationException("Falta la seccion 'Eventos' en appsettings.json.");
opciones.Validar();
builder.Services.AddSingleton(opciones);

// ---------------------------------------------------------------------------
// 2. El cliente de EventBridge
// ---------------------------------------------------------------------------
// Uno solo para toda la aplicacion (Singleton): el cliente reutiliza las
// conexiones HTTPS con AWS, y crear uno por peticion las abriria de nuevo cada
// vez.
//
// Fijate en lo que NO hay: credenciales. El SDK las busca solo, en este orden,
// y usa las primeras que encuentra:
//
//   1. Variables de entorno con claves (AWS_ACCESS_KEY_ID...)
//   2. El perfil que diga AWS_PROFILE  <- en local: testenforce-b, puesto en
//      Properties/launchSettings.json
//   3. El perfil `default`
//   4. El rol del sitio donde corra, si corre dentro de AWS (ECS, Lambda...)
//
// Por eso este codigo no cambiara cuando la API se despliegue en AWS en la
// Fase 8: alli no habra perfil, y el SDK pasara solo al punto 4.
// ---------------------------------------------------------------------------
builder.Services.AddSingleton<IAmazonEventBridge>(
    new AmazonEventBridgeClient(RegionEndpoint.GetBySystemName(opciones.Region)));
builder.Services.AddSingleton<PublicadorDeEventos>();

// ---------------------------------------------------------------------------
// 3. Validacion y errores
// ---------------------------------------------------------------------------
// AddValidation hace que se cumplan los atributos [Required], [Range]... de
// NuevaResenya antes de entrar al endpoint. AddProblemDetails da a todos los
// errores el mismo formato JSON estandar (RFC 9457), en vez de texto suelto.
// ---------------------------------------------------------------------------
builder.Services.AddValidation();
builder.Services.AddProblemDetails();

// ---------------------------------------------------------------------------
// 4. CORS: que paginas de OTRO origen pueden llamar a la API desde un navegador
// ---------------------------------------------------------------------------
// Un origen es esquema + host + puerto. http://localhost:3000 (el frontal) y
// http://localhost:5080 (esta API) son origenes DISTINTOS aunque esten en la
// misma maquina: cambia el puerto. Por defecto, el navegador no deja que una
// pagina lea la respuesta de otro origen salvo que ese otro origen lo autorice
// con cabeceras. Esto es lo que las pone.
//
// La lista sale de la configuracion y NO del codigo:
//   appsettings.json               -> vacia: nadie. Es lo que valdria en produccion
//   appsettings.Development.json   -> http://localhost:3000, solo en desarrollo
//
// Y es una lista concreta, no AllowAnyOrigin: se autoriza lo justo. Solo POST y
// solo la cabecera Content-Type, que es todo lo que usa el formulario.
//
// OJO: CORS NO protege la API. Lo aplica el NAVEGADOR para proteger a quien
// navega. curl, Postman o cualquier servidor ignoran estas cabeceras por
// completo. Proteger la API de verdad (autenticacion, limite de peticiones) es
// otro asunto, pendiente para antes de la Fase 8.
// ---------------------------------------------------------------------------
var origenesPermitidos = builder.Configuration.GetSection("Cors:OrigenesPermitidos").Get<string[]>() ?? [];
builder.Services.AddCors(opciones => opciones.AddPolicy("frontal", politica => politica
    .WithOrigins(origenesPermitidos)
    .WithMethods("POST")
    .WithHeaders("Content-Type")));

var app = builder.Build();

app.UseExceptionHandler();

// Tiene que ir antes de los endpoints: responde a la pregunta previa del
// navegador (el "preflight", una peticion OPTIONS) antes de que llegue a ellos.
app.UseCors("frontal");

app.MapGet("/health", () => Results.Ok(new { status = "Healthy", service = "workingevents-api" }));

// ---------------------------------------------------------------------------
// 5. El endpoint: recibir una resenya y publicarla
// ---------------------------------------------------------------------------
app.MapPost("/resenyas", async (NuevaResenya peticion, PublicadorDeEventos publicador, CancellationToken ct) =>
{
    var evento = new ResenyaEnviada(
        Id: $"rev-{Guid.NewGuid()}",
        Comentario: peticion.Comentario.Trim(),
        Calificacion: peticion.Calificacion,
        Email: peticion.Email.Trim());

    var resultado = await publicador.PublicarAsync(evento, ct);

    // 202 Accepted y no 200 OK, y no por estetica: 202 significa "recibido, se
    // procesara despues". Es exactamente lo que pasa. La API no sabe, ni debe
    // esperar a saber, si la resenya acabara siendo negativa.
    //
    // Si EventBridge la rechazo, 502 Bad Gateway: el fallo no es del cliente
    // (eso seria un 400) sino de un servicio del que dependemos.
    return resultado.Aceptado
        ? Results.Accepted(value: new { evento.Id, resultado.EventId })
        : Results.Problem(
            title: "EventBridge rechazo el evento",
            detail: resultado.Error,
            statusCode: StatusCodes.Status502BadGateway);
});

app.Run();
