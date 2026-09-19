using System.ComponentModel.DataAnnotations;

namespace WorkingEvents.Api.Resenyas;

// ---------------------------------------------------------------------------
// Lo que envia el cliente desde el formulario: la ENTRADA de la API.
// ---------------------------------------------------------------------------
// No lleva Id a proposito: el identificador lo pone el servidor. Si lo eligiera
// el cliente, dos clientes podrian mandar el mismo, o alguien podria reutilizar
// a proposito el de una resenya ajena.
//
// Los atributos entre corchetes son reglas de validacion. .NET las comprueba
// ANTES de ejecutar el endpoint: si alguna falla, responde 400 con el detalle y
// el codigo del endpoint ni llega a ejecutarse. Asi nunca se publica en
// EventBridge un evento con datos imposibles.
// ---------------------------------------------------------------------------
public sealed record NuevaResenya
{
    [Required, StringLength(2000, MinimumLength = 3)]
    public string Comentario { get; init; } = "";

    // Sin Range, una peticion que no traiga calificacion llegaria con 0 (el
    // valor por defecto de un int) y se publicaria como si fuera una nota real.
    [Range(1, 5)]
    public int Calificacion { get; init; }

    [Required, EmailAddress]
    public string Email { get; init; } = "";
}
