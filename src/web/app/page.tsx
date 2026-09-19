import FormularioResenya from "@/componentes/FormularioResenya";

// ---------------------------------------------------------------------------
// La pagina de inicio: la URL "/" sale de que este fichero se llame page.tsx
// y este directamente dentro de app/. En Next.js, las carpetas son las rutas.
// ---------------------------------------------------------------------------
// Este componente NO lleva "use client": se ejecuta en el servidor de Next.js
// y al navegador llega ya convertido en HTML. Es solo texto fijo, no necesita
// reaccionar a nada. La parte interactiva vive en FormularioResenya.
// ---------------------------------------------------------------------------

export default function Inicio() {
  return (
    <main className="pagina">
      <header className="cabecera">
        <p className="marca">WorkingEvents</p>
        <h1>¿Qué tal tu pedido?</h1>
        <p className="subtitulo">
          Cuéntanos tu experiencia. Si algo ha ido mal, alguien del equipo lo sabrá en segundos.
        </p>
      </header>
      <FormularioResenya />
    </main>
  );
}
