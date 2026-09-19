"use client";

// ---------------------------------------------------------------------------
// "use client": este componente se ejecuta en el NAVEGADOR
// ---------------------------------------------------------------------------
// En Next.js, por defecto, los componentes se ejecutan en el servidor y al
// navegador solo llega el HTML resultante. Eso no sirve aqui: un formulario
// tiene que reaccionar a lo que escribe el usuario (estado, clics, envio), y
// eso solo puede pasar en el navegador. Esta primera linea lo pide.
//
// Consecuencia importante: la llamada a la API la hace el NAVEGADOR del
// cliente, no el servidor de Next.js. Por eso entra en juego CORS.
// ---------------------------------------------------------------------------

import { useState, type FormEvent } from "react";
import { enviarResenya, type Resultado } from "@/servicios/resenyas";

const ETIQUETAS = ["", "Muy mala", "Mala", "Normal", "Buena", "Excelente"];

export default function FormularioResenya() {
  // El ESTADO: lo que el componente recuerda entre un dibujado y el siguiente.
  // Cada vez que cambia, React vuelve a dibujar el formulario con el valor nuevo.
  const [comentario, setComentario] = useState("");
  const [calificacion, setCalificacion] = useState(0);
  const [email, setEmail] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [resultado, setResultado] = useState<Resultado | null>(null);

  async function alEnviar(evento: FormEvent<HTMLFormElement>) {
    // Sin esto, el navegador haria un envio clasico: recargaria la pagina y
    // mandaria los datos como formulario, no como JSON.
    evento.preventDefault();

    setEnviando(true);
    setResultado(null);

    const r = await enviarResenya({ comentario: comentario.trim(), calificacion, email: email.trim() });

    setResultado(r);
    setEnviando(false);
    if (r.tipo === "aceptada") {
      setComentario("");
      setCalificacion(0);
      setEmail("");
    }
  }

  const errores = resultado?.tipo === "invalida" ? resultado.errores : {};

  // -------------------------------------------------------------------------
  // Dos validaciones, con papeles distintos
  // -------------------------------------------------------------------------
  // Los atributos required, minLength y type="email" hacen que el NAVEGADOR
  // avise al instante, sin llamar a nadie. Es comodidad para quien escribe.
  //
  // Pero no es seguridad: cualquiera puede saltarselos (con curl, o
  // desactivandolos en la consola). La validacion que manda de verdad es la de
  // la API, y sus errores tambien se muestran aqui, campo a campo.
  // -------------------------------------------------------------------------
  return (
    <form className="formulario" onSubmit={alEnviar}>
      <fieldset className="campo">
        <legend>Tu valoración</legend>
        <div className="estrellas">
          {[1, 2, 3, 4, 5].map((n) => (
            <label key={n} className={n <= calificacion ? "estrella llena" : "estrella"}>
              <input
                type="radio"
                name="calificacion"
                value={n}
                checked={calificacion === n}
                onChange={() => setCalificacion(n)}
                required
              />
              <span aria-hidden="true">★</span>
              <span className="solo-lectores">{n} de 5</span>
            </label>
          ))}
          <span className="etiqueta-estrellas">{ETIQUETAS[calificacion]}</span>
        </div>
        <Errores mensajes={errores.calificacion} />
      </fieldset>

      <div className="campo">
        <label htmlFor="comentario">Tu comentario</label>
        <textarea
          id="comentario"
          value={comentario}
          onChange={(e) => setComentario(e.target.value)}
          rows={5}
          minLength={3}
          maxLength={2000}
          required
          placeholder="¿Qué tal fue? Cuéntanoslo con tus palabras."
        />
        <Errores mensajes={errores.comentario} />
      </div>

      <div className="campo">
        <label htmlFor="email">Tu correo</label>
        <input
          id="email"
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
          placeholder="nombre@ejemplo.com"
        />
        <Errores mensajes={errores.email} />
      </div>

      <button type="submit" disabled={enviando}>
        {enviando ? "Enviando…" : "Enviar reseña"}
      </button>

      {/* aria-live: los lectores de pantalla anuncian el resultado al aparecer. */}
      <div aria-live="polite">
        {resultado && <Aviso resultado={resultado} />}
      </div>
    </form>
  );
}

function Errores({ mensajes }: { mensajes?: string[] }) {
  if (!mensajes?.length) return null;
  return <p className="error-campo">{mensajes.join(" ")}</p>;
}

function Aviso({ resultado }: { resultado: Resultado }) {
  switch (resultado.tipo) {
    case "aceptada":
      // 202 significa "recibida", no "analizada". El texto dice exactamente
      // eso: el analisis ocurre despues, en la Lambda, sin que esta pagina
      // espere por el.
      return (
        <div className="aviso aviso-ok">
          <p><strong>¡Gracias! Hemos recibido tu reseña.</strong></p>
          <p>La revisaremos en unos segundos.</p>
          <p className="detalle">
            Reseña <code>{resultado.id}</code>
            <br />
            Evento <code>{resultado.eventId}</code>
          </p>
        </div>
      );
    case "invalida":
      return (
        <div className="aviso aviso-error">
          <p>Revisa los campos marcados: la API los ha rechazado.</p>
        </div>
      );
    case "error":
      return (
        <div className="aviso aviso-error">
          <p>{resultado.mensaje}</p>
        </div>
      );
  }
}
