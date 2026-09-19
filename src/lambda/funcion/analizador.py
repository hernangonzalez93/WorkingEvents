"""
Analizador de sentimiento por lexico, en espanyol.

Funciona como lo haria una persona con prisa y una lista en la mano: busca
palabras que conoce ("pesimo", "roto", "excelente"), suma lo que pesa cada una
(negativo resta, positivo suma) y mira el total.

NO entiende el texto: solo reconoce palabras. Sus limites estan escritos como
pruebas en pruebas/test_analizador.py, para que queden a la vista en vez de
descubrirse en produccion.

Sin dependencias: solo la biblioteca estandar de Python. No hace falta
empaquetar nada ni instalar nada para probarlo.
"""

import re
import unicodedata
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# El lexico: cuanto pesa cada palabra
# ---------------------------------------------------------------------------
# Las palabras van ya normalizadas (minusculas, sin tildes), igual que queda el
# texto despues de pasar por normalizar(). Asi "Pésimo", "PESIMO" y "pesimo"
# encuentran la misma entrada.
# ---------------------------------------------------------------------------
LEXICO: dict[str, int] = {
    # Muy negativas
    "pesimo": -3, "pesima": -3, "horrible": -3, "terrible": -3, "fatal": -3,
    "estafa": -3, "timo": -3, "fraude": -3, "desastre": -3, "lamentable": -3,
    "inaceptable": -3, "vergonzoso": -3, "asqueroso": -3, "indignante": -3,
    "engano": -3,
    # Negativas
    "malo": -2, "mala": -2, "peor": -2, "roto": -2, "rota": -2,
    "defectuoso": -2, "defectuosa": -2, "danado": -2, "danada": -2,
    "estropeado": -2, "averiado": -2, "sucio": -2, "sucia": -2,
    "grosero": -2, "grosera": -2, "maleducado": -2, "decepcion": -2,
    "decepcionado": -2, "decepcionada": -2, "decepcionante": -2,
    "enfadado": -2, "enfadada": -2, "harto": -2, "harta": -2,
    "mentira": -2, "queja": -2, "reclamacion": -2,
    # Algo negativas
    "retraso": -1, "tarde": -1, "lento": -1, "lenta": -1, "caro": -1,
    "problema": -1, "problemas": -1, "error": -1, "devolucion": -1,
    "reembolso": -1, "faltaba": -1,
    # Positivas
    "bien": 1, "correcto": 1, "funciona": 1, "rapido": 1, "rapida": 1,
    "gracias": 1, "bueno": 2, "buena": 2, "amable": 2, "contento": 2,
    "contenta": 2, "satisfecho": 2, "satisfecha": 2, "recomiendo": 2,
    "repetire": 2, "gusto": 2, "encanta": 2, "encanto": 2,
    # Muy positivas
    "excelente": 3, "perfecto": 3, "perfecta": 3, "genial": 3,
    "fantastico": 3, "maravilloso": 3, "estupendo": 3, "increible": 3,
    "encantado": 3, "encantada": 3,
}

# Expresiones de varias palabras con significado propio. Se buscan ANTES que
# las palabras sueltas: "nadie contesta" es una queja clarisima, aunque ni
# "nadie" ni "contesta" lo sean por separado.
FRASES: dict[tuple[str, ...], int] = {
    ("nadie", "contesta"): -2,
    ("nadie", "responde"): -2,
    ("nadie", "atiende"): -2,
    ("sin", "respuesta"): -2,
    ("no", "funciona"): -2,
    ("no", "llego"): -2,
    ("nunca", "mas"): -3,
    ("tomadura", "de", "pelo"): -3,
}

# Las mas largas primero: si una frase contuviera a otra, gana la completa.
_FRASES_POR_LONGITUD = sorted(FRASES, key=len, reverse=True)

# Palabras que dan la vuelta a lo que viene detras: "no me gusto".
NEGADORES = {"no", "nunca", "jamas", "tampoco", "ni", "nada", "sin"}

# Hasta cuantas palabras hacia atras llega una negacion. En "no me gusto", el
# "no" esta dos posiciones antes de "gusto".
ALCANCE_NEGACION = 3

# Palabras que refuerzan la siguiente: "muy malo" pesa mas que "malo".
INTENSIFICADORES = {
    "muy", "super", "totalmente", "completamente", "extremadamente",
    "realmente", "demasiado", "tan",
}
FACTOR_INTENSIDAD = 1.5

# A partir de cuanto se considera negativo o positivo. Con -2, una sola palabra
# "negativa" (-2) ya basta; una "algo negativa" (-1) sola no.
UMBRAL_NEGATIVO = -2
UMBRAL_POSITIVO = 2


@dataclass
class Resultado:
    puntuacion: float
    sentimiento: str  # NEGATIVO, NEUTRO o POSITIVO
    # Que palabras contaron y cuanto. Van en el correo: una alerta que explica
    # por que salto se revisa en segundos; una que no, obliga a adivinar.
    senales: list[str] = field(default_factory=list)


def normalizar(palabra: str) -> str:
    """'Pésimo' -> 'pesimo'.

    NFD separa cada letra de su tilde ("é" pasa a ser "e" + "´") y luego se
    descartan las tildes sueltas (categoria Unicode "Mn"). La enye sigue el
    mismo camino: "daño" queda "dano", y por eso el lexico la escribe asi.
    """
    descompuesta = unicodedata.normalize("NFD", palabra.lower())
    return "".join(c for c in descompuesta if unicodedata.category(c) != "Mn")


def analizar(texto: str) -> Resultado:
    puntuacion = 0.0
    senales: list[str] = []

    # Se trabaja por tramos separados por puntuacion: una negacion no cruza un
    # punto ni una coma. En "no llego tarde, pero vino roto", el "no" no debe
    # darle la vuelta a "roto".
    for tramo in re.split(r"[.,;:!?¡¿\n]+", texto):
        originales = re.findall(r"\w+", tramo)
        palabras = [normalizar(p) for p in originales]

        i = 0
        while i < len(palabras):
            frase = _frase_en(palabras, i)
            if frase:
                peso = FRASES[frase]
                puntuacion += peso
                senales.append(f"{' '.join(frase)} ({peso:+g})")
                i += len(frase)
                continue

            if palabras[i] in LEXICO:
                peso, descripcion = _ponderar(palabras, originales, i)
                puntuacion += peso
                senales.append(f"{descripcion} ({peso:+g})")
            i += 1

    return Resultado(puntuacion, _clasificar(puntuacion), senales)


def _frase_en(palabras: list[str], i: int) -> tuple[str, ...] | None:
    for frase in _FRASES_POR_LONGITUD:
        if tuple(palabras[i:i + len(frase)]) == frase:
            return frase
    return None


def _ponderar(palabras: list[str], originales: list[str], i: int) -> tuple[float, str]:
    peso = float(LEXICO[palabras[i]])
    descripcion = palabras[i]

    if i > 0 and palabras[i - 1] in INTENSIFICADORES:
        peso *= FACTOR_INTENSIDAD
        descripcion = f"{palabras[i - 1]} {descripcion}"

    # Escribir en mayusculas es gritar, y gritar tambien es intensidad.
    if originales[i].isupper() and len(originales[i]) >= 3:
        peso *= FACTOR_INTENSIDAD
        descripcion += " en mayusculas"

    anteriores = palabras[max(0, i - ALCANCE_NEGACION):i]
    negador = next((p for p in reversed(anteriores) if p in NEGADORES), None)
    if negador:
        peso = -peso
        descripcion = f"{negador} ... {descripcion}"

    return peso, descripcion


def _clasificar(puntuacion: float) -> str:
    if puntuacion <= UMBRAL_NEGATIVO:
        return "NEGATIVO"
    if puntuacion >= UMBRAL_POSITIVO:
        return "POSITIVO"
    return "NEUTRO"
