"""
Construye la CAPA de dependencias de la Lambda en infra/build/capa/.

    python src/lambda/empaquetar.py

Hay que ejecutarlo antes del primer `terraform plan`, y otra vez solo si cambia
requirements.txt. El codigo de la funcion (funcion/*.py) NO pasa por aqui:
Terraform lo empaqueta solo en cada plan, como hasta ahora.

Por que no vale un `pip install` normal: instalaria las librerias para TU
equipo (Windows, x86). Algunas llevan partes compiladas (pydantic-core, jiter)
que no funcionan en la Lambda, que es Linux sobre procesador ARM (arm64). Los
parametros --platform y --only-binary piden a pip la version compilada para
Linux ARM, aunque se ejecute en Windows.
"""

import shutil
import subprocess
import sys
from pathlib import Path

AQUI = Path(__file__).resolve().parent
RAIZ = AQUI.parent.parent
# Lambda exige que las librerias de una capa de Python esten bajo "python/".
DESTINO = RAIZ / "infra" / "build" / "capa" / "python"

if DESTINO.parent.exists():
    shutil.rmtree(DESTINO.parent)
DESTINO.mkdir(parents=True)

subprocess.run(
    [
        sys.executable, "-m", "pip", "install",
        "--requirement", str(AQUI / "requirements.txt"),
        "--target", str(DESTINO),
        "--platform", "manylinux2014_aarch64",   # Linux sobre ARM
        "--implementation", "cp",                # CPython
        "--python-version", "3.13",              # la del runtime de la Lambda
        "--only-binary=:all:",                   # nunca compilar en tu equipo
        "--upgrade", "--quiet", "--disable-pip-version-check",
    ],
    check=True,
)

# Las caches de Python no aportan nada en la Lambda.
for cache in DESTINO.rglob("__pycache__"):
    shutil.rmtree(cache)

paquetes = sorted(p.name for p in DESTINO.iterdir() if p.is_dir() and not p.name.endswith(".dist-info"))
tamanyo = sum(f.stat().st_size for f in DESTINO.rglob("*") if f.is_file())
print(f"Capa lista en {DESTINO.relative_to(RAIZ)}")
print(f"  {len(paquetes)} paquetes, {tamanyo / 1_000_000:.1f} MB sin comprimir")
print(f"  {', '.join(paquetes)}")
