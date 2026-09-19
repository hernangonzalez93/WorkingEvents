# El análisis de sentimiento

Cómo decide la Lambda si una reseña es negativa: las opciones que había, por qué se eligió la
que se eligió y cómo funciona por dentro, con sus límites a la vista.

---

## 1. Las opciones

| # | Opción | Qué es | Coste | Calidad | Complejidad |
|---|---|---|---|---|---|
| A | **Amazon Comprehend** | Servicio gestionado de AWS. Devuelve `POSITIVE`, `NEGATIVE`, `NEUTRAL` o `MIXED` con porcentajes de confianza. Admite español | ~0,0003 $ por reseña (mínimo 3 unidades de 100 caracteres). 50.000 unidades al mes gratis durante 12 meses | Buena para decir si es negativa, pero no explica por qué | Muy baja: solo permisos de IAM |
| B | **Amazon Bedrock con Claude** | Un LLM dentro de AWS. Se autentica con IAM, **sin clave que gestionar** | Céntimos al mes con Claude Haiku | Excelente: puede devolver sentimiento, urgencia, categoría y resumen | Media |
| C | **API de Anthropic + Secrets Manager** | Llamada HTTPS a api.anthropic.com con la clave guardada en la caja fuerte | Igual que B, más 0,40 $/mes por el secreto | Igual que B | Media-alta: gestionar la clave |
| D | **Modelo local en la Lambda** | Una librería como VADER o un transformer pequeño dentro del paquete | $0 | Mala en español (VADER es solo inglés); un transformer decente pesa cientos de MB | Alta |
| E | **Solo reglas** | `if calificacion <= 2: negativa` | $0 | No mira el texto | Nula |

La recomendación inicial fue **empezar con Comprehend y migrar después a Bedrock**, para ver el
flujo funcionando cuanto antes y tener luego un "antes" con el que comparar el LLM.

Sobre la opción C: Bedrock da el mismo Claude sin clave de API, porque la Lambda se autentica
con su rol. Así desaparecen Secrets Manager, el riesgo de filtrar la clave y los 0,40 $ al
mes. La opción C tiene sentido si el objetivo es **aprender Secrets Manager**.

## 2. Lo que pasó: la cuenta no deja usar los servicios de IA

Comprehend, Translate y Bedrock están bloqueados en la cuenta, como se detalla en
[ENTORNO](ENTORNO.md#31-los-servicios-de-ia-de-aws-están-bloqueados). Eso deja fuera las
opciones A y B.

La decisión final:

| Fase | Analizador | Por qué |
|---|---|---|
| **4** | **Propio, en Python puro** | Cero dependencias y cero coste. Permitió probar el flujo completo de punta a punta |
| **7** | **Un modelo de IA, con el proveedor como parámetro** (hoy OpenAI `gpt-5.6-luna`) | Son llamadas HTTPS a servicios externos, no servicios de IA de AWS, así que esquivan el bloqueo. Las claves van en Secrets Manager, que sí funciona en la cuenta |

Tener primero el analizador propio tuvo una ventaja: en la Fase 7 se compararon los dos sobre
las mismas reseñas. La IA acertó 10 de 10 y el léxico 3 de 10
([IA](IA.md#10-comparación-1-léxico-contra-gpt-56-sol)). El léxico sigue en el código como
**respaldo**: si la IA falla, analiza él y salta una alarma.

## 3. El analizador propio

Código: [`src/lambda/funcion/analizador.py`](../src/lambda/funcion/analizador.py).

### 3.1 La idea

Es lo que haría una persona con prisa y una lista en la mano: busca palabras que conoce, suma
lo que pesa cada una (lo negativo resta, lo positivo suma) y mira el total. **No entiende el
texto**: solo reconoce palabras.

### 3.2 El léxico

Son unas 90 palabras, cada una con un peso:

| Peso | Ejemplos |
|---|---|
| **-3**, muy negativas | pésimo, horrible, estafa, desastre, inaceptable |
| **-2**, negativas | malo, roto, defectuoso, decepcionado, grosero |
| **-1**, algo negativas | retraso, tarde, lento, problema |
| **+1**, algo positivas | bien, funciona, rápido, gracias |
| **+2**, positivas | bueno, amable, recomiendo, gustó |
| **+3**, muy positivas | excelente, perfecto, genial, increíble |

Además hay **frases** de varias palabras con significado propio, como "nadie contesta" (-2),
"no funciona" (-2) o "nunca más" (-3). "Nadie contesta" es una queja clarísima, aunque ni
"nadie" ni "contesta" lo sean por separado.

### 3.3 Paso a paso, con un ejemplo real

La reseña: *"El pedido llego tarde y roto. Nadie contesta al telefono."*

**Paso 1: normalizar.** Se pasa todo a minúsculas y se quitan las tildes, para que "Pésimo",
"PÉSIMO" y "pesimo" encuentren la misma entrada del léxico.

Para quitar las tildes, la forma Unicode **NFD** separa cada letra de su tilde ("é" se
convierte en "e" + "´") y después se descartan las tildes sueltas. La ñ sigue el mismo camino,
así que en el léxico "dañado" se escribe `danado`.

**Paso 2: partir en tramos** por la puntuación:

```
Tramo 1:  el · pedido · llego · tarde · y · roto
Tramo 2:  nadie · contesta · al · telefono
```

Se hace porque una negación no debe cruzar un punto ni una coma.

**Paso 3: recorrer cada tramo**, buscando primero frases y después palabras sueltas:

| Palabra | ¿Frase? | ¿En el léxico? | Qué pasa | Total |
|---|---|---|---|---|
| el, pedido, llego | no | no | se ignoran | 0 |
| **tarde** | no | **-1** | nada la modifica | **-1** |
| y | no | no | se ignora | -1 |
| **roto** | no | **-2** | nada la modifica | **-3** |
| **nadie contesta** | **sí: -2** | — | se cuentan las dos palabras de una vez | **-5** |
| al, telefono | no | no | se ignoran | -5 |

**Paso 4: clasificar el total.**

```
total <= -2   ->  NEGATIVO
total >= +2   ->  POSITIVO
en medio      ->  NEUTRO
```

Con -5, la reseña es NEGATIVA. Con un umbral de -2, basta una palabra "negativa" (-2), pero una
sola "algo negativa" (-1) no llega.

### 3.4 Los tres modificadores

Antes de sumarse, el peso de cada palabra puede cambiar:

| Modificador | Ejemplo | Qué hace | Resultado |
|---|---|---|---|
| **Intensificador** justo antes | "**muy** malo" | × 1,5 | -2 → **-3** |
| **Mayúsculas** (3 letras o más) | "**PESIMO**" | × 1,5, porque escribir en mayúsculas es gritar | -3 → **-4,5** |
| **Negación** en las 3 palabras anteriores | "**no** me gustó" | invierte el signo | +2 → **-2** |

La negación mira **hasta 3 palabras atrás**. En "no me gustó", el "no" está dos posiciones antes
de "gustó". Cuentan como negación *no, nunca, jamás, tampoco, ni, nada* y *sin*; por eso
"llegó **sin** problemas" suma en positivo.

### 3.5 Las señales: por qué ha saltado la alerta

Cada palabra que cuenta queda anotada, por ejemplo `tarde (-1), roto (-2), nadie contesta (-2)`.
Las señales **van en el correo**: una alerta que dice por qué ha saltado se revisa en segundos;
una que no lo dice obliga a adivinar.

## 4. La decisión de avisar

Código: `requiere_alerta()` en [`alertas.py`](../src/lambda/funcion/alertas.py).

A la Lambda solo llegan reseñas de 1 a 3 estrellas, porque la regla de EventBridge ya filtró el
resto. Entre ellas, se avisa si se cumple alguna de estas dos reglas, comprobadas en orden:

| # | Regla | Por qué |
|---|---|---|
| 1 | El texto es **NEGATIVO** | Es el caso principal: analizar el contenido |
| 2 | La calificación es **1 estrella**, diga lo que diga el texto | Una estrella casi nunca es un elogio. Si el texto no tiene palabras conocidas ("Llegó el martes."), la nota basta |

Si no se cumple ninguna, por ejemplo con 3 estrellas y "Cumple su función.", no se avisa, pero
la reseña queda registrada en el log. La función devuelve también el **motivo**, que va al log y
al correo.

> **Nota de la Fase 7.** Ahora llegan a la Lambda **todas** las reseñas, no solo las de 1 a 3
> estrellas, y hay una regla más entre las dos: se avisa también si la **urgencia es ALTA**, algo
> que solo detecta la IA ([IA](IA.md#62-la-urgencia)).

## 5. Los límites, escritos como pruebas

Un analizador por léxico se equivoca de formas previsibles. En lugar de esconderlo, esos fallos
están escritos como pruebas en la clase `LimitesConocidos` de
[`test_analizador.py`](../src/lambda/pruebas/test_analizador.py):

| Texto | Lo que entiende una persona | Lo que calcula el analizador |
|---|---|---|
| "Genial, otra vez me llega roto" | Una queja con sarcasmo | genial +3, roto -2: **+1, NEUTRO** ❌ |
| "Llegó por la tarde" | Neutro | "tarde" contada como retraso: **-1** ❌ |
| "Una chapuza" | Muy negativo | "chapuza" no está en el léxico: **0, NEUTRO** ❌ |
| "No llegó tarde" | Positivo: llegó a tiempo | Encaja con la frase "no llegó": **-2** ❌ |

Esas pruebas **pasan porque el analizador se equivoca**. Si un día alguna empieza a fallar, es
que su comportamiento cambió y hay que mirar por qué. Son justo los casos en los que un LLM
debería hacerlo mejor en la Fase 7.

## 6. La prueba que pasaba por el motivo equivocado

El último límite de la tabla se descubrió escribiendo las pruebas, y la historia merece
contarse.

Había una prueba llamada "la negación no cruza la coma", con la frase *"No llego tarde, pero
vino roto"*. **Pasó a la primera.** Pero al mirar las señales para ver por qué pasaba, apareció
esto:

```
no llego (-2),  no ... tarde (+1),  roto (-2)   ->  -3, NEGATIVO
```

El resultado era negativo **por la frase "no llego"**, no por lo que la prueba decía comprobar.
La prueba estaba en verde sin demostrar nada. Se corrigió para que comprobara la señal concreta
de "roto" en lugar del total, y el caso de "no llegó tarde" pasó a la lista de límites.

La lección: **una prueba en verde solo vale si fallaría cuando debe fallar.** Cuando una prueba
pasa a la primera, merece la pena preguntarse por qué.

## 7. Ejecutar las pruebas

No hace falta instalar nada:

```bash
python -B -m unittest discover -s src/lambda/pruebas -v
```

Son 21 pruebas: 15 del analizador (11 de lo que hace bien y 4 de sus límites) y 6 de la apertura
del mensaje, la decisión y el correo. La `-B` evita que Python deje cachés (`__pycache__`) dentro
de `funcion/`, aunque el empaquetado de Terraform también las excluye.
