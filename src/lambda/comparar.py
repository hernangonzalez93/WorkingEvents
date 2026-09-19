"""
Lanza la Lambda comparadora y muestra el resultado en una tabla.

    python src/lambda/comparar.py [--motores lexico,openai,openai:gpt-5.6-luna] [fichero.json]

Por defecto usa pruebas/comparacion.json y todos los motores con secreto. Solo
necesita el AWS CLI con tu perfil: las claves de las APIs no pasan nunca por
tu equipo.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]

argumentos = argparse.ArgumentParser(description="Compara los motores de analisis.")
argumentos.add_argument("fichero", nargs="?", default=RAIZ / "pruebas" / "comparacion.json", type=Path)
argumentos.add_argument("--motores", help="Lista separada por comas: lexico,anthropic,openai")
args = argumentos.parse_args()

evento = json.loads(args.fichero.read_text(encoding="utf-8"))
if args.motores:
    evento["motores"] = args.motores.split(",")

with tempfile.TemporaryDirectory() as tmp:
    entrada = Path(tmp) / "entrada.json"
    entrada.write_text(json.dumps(evento, ensure_ascii=False), encoding="utf-8")
    salida = Path(tmp) / "salida.json"
    respuesta = subprocess.run(
        ["aws", "lambda", "invoke",
         "--function-name", "workingevents-comparador",
         "--region", "eu-west-1",
         # fileb:// manda los bytes tal cual: con file://, el CLI de Windows
         # podria leer el JSON con otra codificacion y romper las tildes.
         "--payload", f"fileb://{entrada}",
         "--cli-read-timeout", "300",
         str(salida)],
        capture_output=True, text=True, env=os.environ,
    )
    if respuesta.returncode != 0:
        sys.exit(f"Fallo la invocacion:\n{respuesta.stderr}")
    if '"FunctionError"' in respuesta.stdout:
        sys.exit(f"La comparadora fallo:\n{salida.read_text(encoding='utf-8')}")
    filas = json.loads(salida.read_text(encoding="utf-8"))

motores = [k for k in filas[0] if k not in ("comentario", "calificacion")]
coste_tokens = {m: [0, 0] for m in motores}
ancho = max(len(m) for m in motores)

for n, fila in enumerate(filas, 1):
    print(f"\n{n}. [{fila['calificacion']}*] {fila['comentario']}")
    for motor in motores:
        r = fila[motor]
        if "error" in r:
            print(f"   {motor:<{ancho}} ERROR {r['error']} (HTTP {r['http']})")
            continue
        urgencia = f" · urgencia {r['urgencia']}" if r["urgencia"] else ""
        print(f"   {motor:<{ancho}} {r['sentimiento']:<9}{urgencia:<18} {r['milisegundos']:>6} ms   {r['modelo']}")
        if r["explicacion"]:
            print(f"   {'':<{ancho}} -> {r['explicacion']}")
        if r["tokens"][0]:
            coste_tokens[motor][0] += r["tokens"][0]
            coste_tokens[motor][1] += r["tokens"][1]

print("\nTokens consumidos en total (entrada / salida):")
for motor, (entrada_t, salida_t) in coste_tokens.items():
    if entrada_t:
        print(f"   {motor:<{ancho}} {entrada_t} / {salida_t}")
