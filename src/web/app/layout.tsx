import type { Metadata } from "next";
import "./globals.css";

// El layout es el marco comun a todas las paginas: el <html>, el <body> y lo
// que se repite. Next.js mete dentro, en {children}, la pagina que toque segun
// la URL. Aqui solo hay una.

export const metadata: Metadata = {
  title: "WorkingEvents · Deja tu reseña",
  description: "Formulario de reseñas del laboratorio WorkingEvents.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="es">
      <body>{children}</body>
    </html>
  );
}
