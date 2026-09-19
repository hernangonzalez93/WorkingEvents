// ---------------------------------------------------------------------------
// La unica pieza del frontal que habla con la API de .NET.
// ---------------------------------------------------------------------------
// El formulario no sabe nada de HTTP: llama a enviarResenya() y recibe un
// Resultado ya interpretado. Es el mismo reparto que en la API, donde el
// endpoint no sabe nada de EventBridge y se lo pide a PublicadorDeEventos.
// ---------------------------------------------------------------------------

// Sale de .env.local. Next.js SUSTITUYE esta expresion por el texto de la URL
// al compilar, y ese texto queda dentro del JavaScript que descarga el
// navegador. Por eso solo puede ser algo publico.
const API_URL = process.env.NEXT_PUBLIC_API_URL;

export type NuevaResenya = {
  comentario: string;
  calificacion: number;
  email: string;
};

// Las tres cosas que pueden pasar, y nada mas. El formulario tiene que
// contemplar las tres: TypeScript no le deja olvidarse de ninguna.
export type Resultado =
  | { tipo: "aceptada"; id: string; eventId: string }
  | { tipo: "invalida"; errores: Record<string, string[]> }
  | { tipo: "error"; mensaje: string };

export async function enviarResenya(resenya: NuevaResenya): Promise<Resultado> {
  if (!API_URL) {
    return { tipo: "error", mensaje: "Falta NEXT_PUBLIC_API_URL en .env.local." };
  }

  let respuesta: Response;
  try {
    respuesta = await fetch(`${API_URL}/resenyas`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(resenya),
    });
  } catch {
    // -----------------------------------------------------------------------
    // fetch solo falla cuando NO hay respuesta que leer
    // -----------------------------------------------------------------------
    // Un 400 o un 502 NO llegan aqui: son respuestas, y fetch las devuelve con
    // normalidad. Aqui solo se llega si la API esta apagada... o si el
    // navegador ha bloqueado la respuesta por CORS.
    //
    // Y desde el codigo no hay forma de distinguir un caso del otro: el
    // navegador oculta el motivo a proposito, para no dar pistas a una pagina
    // sobre servidores a los que no deberia poder mirar. El motivo real solo
    // aparece en la consola del navegador (F12).
    // -----------------------------------------------------------------------
    return {
      tipo: "error",
      mensaje:
        "No se pudo contactar con la API. Comprueba que está arrancada; si lo está, " +
        "abre la consola del navegador (F12): puede ser un bloqueo de CORS.",
    };
  }

  if (respuesta.status === 202) {
    const cuerpo: { id: string; eventId: string } = await respuesta.json();
    return { tipo: "aceptada", id: cuerpo.id, eventId: cuerpo.eventId };
  }

  if (respuesta.status === 400) {
    // El formato de errores de .NET (ProblemDetails, RFC 9457):
    //   { "errors": { "Comentario": ["..."], "Calificacion": ["..."] } }
    // Las claves llegan con mayuscula, como las propiedades de C#. Se pasan a
    // minuscula para que coincidan con los nombres de los campos del formulario.
    const problema: { errors?: Record<string, string[]> } = await respuesta.json();
    const errores = Object.fromEntries(
      Object.entries(problema.errors ?? {}).map(([campo, mensajes]) => [campo.toLowerCase(), mensajes]),
    );
    return { tipo: "invalida", errores };
  }

  // 502 u otro: la API respondio, pero algo fallo por detras.
  const problema: { title?: string } | null = await respuesta.json().catch(() => null);
  return {
    tipo: "error",
    mensaje: problema?.title ?? `La API respondió con un error inesperado (${respuesta.status}).`,
  };
}
