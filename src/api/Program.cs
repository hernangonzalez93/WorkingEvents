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

var app = builder.Build();

app.UseExceptionHandler();

app.MapGet("/health", () => Results.Ok(new { status = "Healthy", service = "workingevents-api" }));

// ---------------------------------------------------------------------------
// 4. El endpoint: recibir una resenya y publicarla
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
