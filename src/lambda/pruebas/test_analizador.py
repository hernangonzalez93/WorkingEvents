"""
Pruebas del analizador. Se ejecutan sin instalar nada:

    python -B -m unittest discover -s src/lambda/pruebas -v

Hay dos clases de prueba. Las primeras dicen lo que el analizador HACE BIEN.
Las de LimitesConocidos dicen lo que hace MAL, a proposito: son la
documentacion honesta de un analizador por lexico. Si un dia una de ellas
falla, es que el comportamiento cambio y hay que mirar por que.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "funcion"))

from analizador import analizar, normalizar  # noqa: E402


class LoQueHaceBien(unittest.TestCase):

    def test_resenya_de_la_fase_2_es_negativa(self):
        r = analizar("El pedido llego con dos dias de retraso y el producto venia roto. "
                     "Nadie responde al telefono. Pesimo servicio.")
        self.assertEqual(r.sentimiento, "NEGATIVO")
        # retraso -1, roto -2, nadie responde -2, pesimo -3
        self.assertEqual(r.puntuacion, -8)

    def test_resenya_positiva(self):
        r = analizar("Todo perfecto, llego antes de lo previsto y la calidad es excelente. Repetire seguro.")
        self.assertEqual(r.sentimiento, "POSITIVO")

    def test_tildes_y_mayusculas_dan_igual_para_encontrar_la_palabra(self):
        self.assertEqual(normalizar("Pésimo"), "pesimo")
        self.assertEqual(normalizar("DAÑADO"), "danado")

    def test_negacion_da_la_vuelta(self):
        self.assertEqual(analizar("No me gusto").sentimiento, "NEGATIVO")
        self.assertEqual(analizar("No lo recomiendo").sentimiento, "NEGATIVO")
        self.assertEqual(analizar("El producto no es malo").sentimiento, "POSITIVO")

    def test_sin_problemas_es_bueno(self):
        self.assertGreater(analizar("Llego sin problemas").puntuacion, 0)

    def test_la_negacion_no_cruza_la_coma(self):
        # El "no" le da la vuelta a "lento", pero no a "roto", que va tras la
        # coma. Se comprueba la SENAL de "roto", no el total: el total podria
        # salir negativo por otros motivos y la prueba pasaria sin demostrar
        # nada (ya ocurrio una vez).
        r = analizar("No fue lento, pero vino roto")
        self.assertIn("no ... lento (+1)", r.senales)
        self.assertIn("roto (-2)", r.senales)

    def test_intensificador_pesa_mas(self):
        self.assertLess(analizar("muy malo").puntuacion, analizar("malo").puntuacion)

    def test_gritar_pesa_mas(self):
        self.assertLess(analizar("PESIMO").puntuacion, analizar("pesimo").puntuacion)

    def test_frase_de_varias_palabras(self):
        self.assertEqual(analizar("Nadie contesta").sentimiento, "NEGATIVO")

    def test_texto_sin_palabras_conocidas_es_neutro(self):
        r = analizar("Llego el martes por la manyana.")
        self.assertEqual(r.sentimiento, "NEUTRO")
        self.assertEqual(r.senales, [])

    def test_las_senales_explican_la_puntuacion(self):
        self.assertEqual(analizar("muy malo").senales, ["muy malo (-3)"])


class LimitesConocidos(unittest.TestCase):
    """Lo que un analizador por lexico NO sabe hacer. Estas pruebas pasan
    porque el analizador se equivoca: documentan el fallo, no lo celebran."""

    def test_no_entiende_el_sarcasmo(self):
        # Una persona lee una queja. El lexico suma "genial" (+3) y "roto" (-2).
        r = analizar("Genial, otra vez me llega roto")
        self.assertNotEqual(r.sentimiento, "NEGATIVO")

    def test_no_distingue_significados_de_una_misma_palabra(self):
        # "tarde" como retraso y "tarde" como momento del dia pesan lo mismo.
        self.assertEqual(analizar("Llego por la tarde").puntuacion, -1)

    def test_confunde_no_llego_tarde_con_no_llego(self):
        # "No llego tarde" significa que llego a tiempo. Pero encaja con la
        # frase ("no", "llego"), pensada para "el pedido no llego", y cuenta
        # como queja. Se deja la frase porque la queja es mucho mas frecuente
        # que el elogio.
        r = analizar("No llego tarde")
        self.assertIn("no llego (-2)", r.senales)

    def test_no_conoce_palabras_fuera_de_la_lista(self):
        # "chapuza" es clarisimamente negativa, pero no esta en el lexico.
        self.assertEqual(analizar("Una chapuza").sentimiento, "NEUTRO")


if __name__ == "__main__":
    unittest.main()
