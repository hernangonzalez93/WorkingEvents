using System.Text.Json;
using Amazon.EventBridge;
using Amazon.EventBridge.Model;
using WorkingEvents.Api.Resenyas;

namespace WorkingEvents.Api.Eventos;

// ---------------------------------------------------------------------------
// Rellena el formulario de PutEvents y lo envia.
// ---------------------------------------------------------------------------
// Es el MISMO formulario de cuatro campos que se mando a mano con el CLI en la
// prueba de la Fase 2 (Source, DetailType, EventBusName, Detail). Cambia la
// puerta, no el tramite.
// ---------------------------------------------------------------------------
public sealed class PublicadorDeEventos(IAmazonEventBridge eventBridge, OpcionesEventos opciones)
{
    // JsonSerializerDefaults.Web escribe los nombres en camelCase:
    // `calificacion`, no `Calificacion`.
    //
    // Esto NO es cosmetico. La regla busca `detail.calificacion` y distingue
    // mayusculas de minusculas. Con el serializador por defecto saldria
    // `Calificacion`, NINGUN evento encajaria, y todos se descartarian sin un
    // solo error en ninguna parte.
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public async Task<ResultadoPublicacion> PublicarAsync(ResenyaEnviada evento, CancellationToken ct)
    {
        var entrada = new PutEventsRequestEntry
        {
            EventBusName = opciones.Bus,
            Source = opciones.Source,
            DetailType = nameof(ResenyaEnviada),

            // Detail es TEXTO que contiene JSON, igual que en el fichero de
            // pruebas. Serialize convierte el objeto en ese texto.
            Detail = JsonSerializer.Serialize(evento, Json),
        };

        var respuesta = await eventBridge.PutEventsAsync(new PutEventsRequest { Entries = [entrada] }, ct);

        // LA TRAMPA DE PutEvents: si EventBridge rechaza un evento, la llamada
        // NO lanza una excepcion. Responde con exito y apunta el rechazo en
        // FailedEntryCount y en el ErrorCode de esa entrada. Si no se mira aqui,
        // el error desaparece sin dejar rastro y el cliente cree que todo fue bien.
        var resultado = respuesta.Entries?.FirstOrDefault();

        if ((respuesta.FailedEntryCount ?? 0) > 0 || string.IsNullOrEmpty(resultado?.EventId))
        {
            return new ResultadoPublicacion(null, $"{resultado?.ErrorCode}: {resultado?.ErrorMessage}");
        }

        return new ResultadoPublicacion(resultado.EventId, null);
    }
}

// EventId es el numero de seguimiento que asigna EventBridge. Error solo tiene
// valor si el evento fue rechazado.
public sealed record ResultadoPublicacion(string? EventId, string? Error)
{
    public bool Aceptado => EventId is not null;
}
