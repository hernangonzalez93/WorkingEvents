namespace WorkingEvents.Api.Resenyas;

// ---------------------------------------------------------------------------
// El EVENTO: lo que se publica en EventBridge y acaba en el campo `detail`.
// ---------------------------------------------------------------------------
// Es un contrato con piezas que este codigo no ve: la regla de EventBridge lee
// `detail.calificacion` y la Lambda leera los cuatro campos.
//
// Cambiar un nombre aqui NO da error de compilacion en ningun sitio. Lo que
// pasa es peor: la regla deja de encajar y los eventos se descartan en
// silencio. Por eso este fichero se toca con cuidado.
//
// El nombre del tipo tambien importa: se usa como `DetailType`, que es lo
// segundo que comprueba la regla.
// ---------------------------------------------------------------------------
public sealed record ResenyaEnviada(
    string Id,
    string Comentario,
    int Calificacion,
    string Email);
