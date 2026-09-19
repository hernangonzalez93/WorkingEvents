namespace WorkingEvents.Api.Eventos;

// ---------------------------------------------------------------------------
// A que bus se publica. Se lee de la seccion "Eventos" de appsettings.json.
// ---------------------------------------------------------------------------
// Estos valores NO son secretos: son nombres. Lo que si seria secreto (las
// credenciales de AWS) no aparece en ningun fichero de este proyecto.
// ---------------------------------------------------------------------------
public sealed record OpcionesEventos
{
    public string Region { get; init; } = "";
    public string Bus { get; init; } = "";
    public string Source { get; init; } = "";

    // Se comprueba al ARRANCAR, no al publicar. Si falta un valor, la API se
    // niega a arrancar con un mensaje claro, en vez de arrancar bien y fallar
    // mas tarde con la primera resenya.
    public void Validar()
    {
        if (string.IsNullOrWhiteSpace(Region) || string.IsNullOrWhiteSpace(Bus) || string.IsNullOrWhiteSpace(Source))
        {
            throw new InvalidOperationException(
                "Configuracion incompleta: la seccion 'Eventos' de appsettings.json necesita Region, Bus y Source.");
        }
    }
}
