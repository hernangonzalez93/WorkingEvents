"""Pruebas de la apertura del mensaje y de la decision de avisar."""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "funcion"))

from alertas import componer_mensaje, extraer_resenya, requiere_alerta  # noqa: E402
from analizador import analizar  # noqa: E402


def registro_sqs(calificacion: int, comentario: str) -> dict:
    """Un mensaje con la misma forma que el que llego a la cola en la Fase 3."""
    sobre = {
        "version": "0",
        "id": "67d53897-9da0-a0dc-20fe-7e787aefef28",
        "detail-type": "ResenyaEnviada",
        "source": "workingevents.api",
        "time": "2026-09-19T11:14:26Z",
        "detail": {
            "id": "rev-prueba",
            "comentario": comentario,
            "calificacion": calificacion,
            "email": "cliente@ejemplo.com",
        },
    }
    # El Body es TEXTO: json.dumps lo convierte, igual que hace SQS.
    return {"messageId": "m-1", "body": json.dumps(sobre)}


class AbrirLasCapas(unittest.TestCase):

    def test_saca_la_carta_y_los_datos_del_sobre(self):
        r = extraer_resenya(registro_sqs(2, "Llego roto"))
        self.assertEqual(r.id, "rev-prueba")
        self.assertEqual(r.calificacion, 2)
        self.assertEqual(r.event_id, "67d53897-9da0-a0dc-20fe-7e787aefef28")

    def test_mensaje_sin_detail_lanza_excepcion(self):
        # Asi acaba en la cola de mensajes muertos tras tres intentos.
        with self.assertRaises(KeyError):
            extraer_resenya({"messageId": "m-1", "body": json.dumps({"id": "x"})})


class DecidirSiSeAvisa(unittest.TestCase):

    def decidir(self, calificacion, comentario):
        resenya = extraer_resenya(registro_sqs(calificacion, comentario))
        return requiere_alerta(resenya, analizar(comentario))

    def test_texto_negativo_avisa(self):
        self.assertTrue(self.decidir(3, "Pesimo servicio")[0])

    def test_una_estrella_avisa_aunque_el_texto_sea_neutro(self):
        alerta, motivo = self.decidir(1, "Llego el martes.")
        self.assertTrue(alerta)
        self.assertIn("1 estrella", motivo)

    def test_tres_estrellas_y_texto_neutro_no_avisa(self):
        self.assertFalse(self.decidir(3, "Cumple su funcion.")[0])


class LaUrgenciaDeLaIA(unittest.TestCase):

    def test_urgencia_alta_avisa_aunque_el_texto_no_sea_negativo(self):
        from analizador_llm import a_resultado
        resenya = extraer_resenya(registro_sqs(5, "Me encanta, pero me habeis cobrado dos veces"))
        resultado = a_resultado({"sentimiento": "POSITIVO", "urgencia": "ALTA",
                                 "explicacion": "Cobro duplicado.", "fragmentos": []}, "claude-opus-5")
        alerta, motivo = requiere_alerta(resenya, resultado)
        self.assertTrue(alerta)
        self.assertIn("urgencia alta", motivo)

    def test_el_correo_de_la_ia_dice_urgencia_explicacion_y_modelo(self):
        from analizador_llm import a_resultado
        resenya = extraer_resenya(registro_sqs(2, "Llego roto"))
        resultado = a_resultado({"sentimiento": "NEGATIVO", "urgencia": "MEDIA",
                                 "explicacion": "Producto danado.", "fragmentos": ["Llego roto"]}, "gpt-5.6-sol")
        asunto, cuerpo = componer_mensaje(resenya, resultado, "el texto es negativo")
        self.assertIn("[MEDIA]", asunto)
        self.assertIn("Explicación:   Producto danado.", cuerpo)
        self.assertIn("Analizado con: gpt-5.6-sol", cuerpo)
        self.assertNotIn("puntuación", cuerpo)       # la IA no da puntuacion

    def test_el_correo_del_lexico_no_tiene_lineas_de_ia(self):
        resenya = extraer_resenya(registro_sqs(2, "Llego roto"))
        asunto, cuerpo = componer_mensaje(resenya, analizar("Llego roto"), "el texto es negativo")
        self.assertNotIn("[", asunto)
        self.assertNotIn("Urgencia:", cuerpo)
        self.assertIn("Analizado con: lexico", cuerpo)


class ComponerElCorreo(unittest.TestCase):

    def test_asunto_cabe_en_el_limite_de_sns_y_sin_saltos(self):
        resenya = extraer_resenya(registro_sqs(2, "Llego roto"))
        asunto, cuerpo = componer_mensaje(resenya, analizar("Llego roto"), "el texto es negativo")
        self.assertLess(len(asunto), 100)
        self.assertNotIn("\n", asunto)
        self.assertIn("Llego roto", cuerpo)
        self.assertIn("cliente@ejemplo.com", cuerpo)


if __name__ == "__main__":
    unittest.main()
