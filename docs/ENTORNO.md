# El entorno, la cuenta y sus trampas

Lo que hay que saber del puesto de trabajo y de la cuenta de AWS antes de tocar nada. Casi todo
lo de este documento se descubrió **al fallar**, y está escrito para que no vuelva a pasar.

---

## 1. Herramientas

| Herramienta | Versión usada |
|---|---|
| .NET SDK | 10.0.400 |
| Node | 22.18 |
| Python | 3.13.3 |
| AWS CLI | 2.36 |
| Terraform | 1.15.8 |
| Git | 2.50 |

## 2. Perfiles y cuentas: asegúrate de estar en la correcta

En el equipo había dos perfiles de AWS con nombres casi iguales, y apuntaban a **cuentas
distintas**:

| Perfil | Tipo | Cuenta |
|---|---|---|
| `testenforce` | SSO (inicio de sesión único) | Otra cuenta, sin relación con este proyecto |
| `testenforce-b` | Usuario IAM con claves | **La cuenta del proyecto** |

Al principio se eligió el perfil equivocado. La lección es que **nunca se debe suponer en qué
cuenta se está**. Hay que comprobarlo:

```powershell
aws sts get-caller-identity --profile testenforce-b
```

Terraform lo comprueba solo: el **guardia de cuenta** (`infra/cuenta.tf`) compara la cuenta de
las credenciales con `expected_account_id` y detiene el plan si no coinciden, antes de crear
nada. Se explica en [INFRAESTRUCTURA](INFRAESTRUCTURA.md#5-cuentatf-el-guardia-de-cuenta).

## 3. Limitaciones de la cuenta

La cuenta del proyecto tiene tres limitaciones que condicionaron el diseño. Las tres apuntan a
lo mismo: **una cuenta que no está completamente verificada**.

### 3.1 Los servicios de IA de AWS están bloqueados

Al probar Amazon Comprehend, falló. La investigación, paso a paso:

| Prueba | Resultado |
|---|---|
| Permisos del usuario | `AdministratorAccess`, así que **no es un problema de permisos** |
| Comprehend `DetectSentiment` | ❌ `SubscriptionRequiredException` |
| Amazon Translate | ❌ `SubscriptionRequiredException` |
| Bedrock: listar modelos | ✅ Aparecen los modelos de Claude, con perfiles de inferencia `eu.*` activos |
| Bedrock: **invocar** Claude Haiku 4.5 | ❌ `ValidationException: Operation not allowed` |
| Bedrock: invocar Nova Micro, un modelo de Amazon | ❌ `Operation not allowed` |
| SQS, SNS, Secrets Manager | ✅ Funcionan |

El detalle que delata la causa: **listar los modelos funciona, pero invocarlos no**, y falla
igual con un modelo de Amazon que con uno de Anthropic. Eso descarta un permiso de IAM o un
problema con un proveedor concreto. Es la cuenta.

La analogía: tienes las llaves de todo el edificio, pero ciertas salas siguen cerradas porque
el contrato de alquiler todavía no está firmado del todo.

Suele resolverse completando los datos de facturación en la consola y, si no basta, abriendo un
caso en AWS Support. Mientras tanto, el analizador de sentimiento se hizo en Python puro. Se
explica en [ANALISIS-DE-SENTIMIENTO](ANALISIS-DE-SENTIMIENTO.md).

### 3.2 Límite de 10 ejecuciones simultáneas de Lambda

```
ConcurrenciaTotal: 10        <- una cuenta normal tiene 1000
```

La **concurrencia** es cuántas copias de las funciones pueden ejecutarse **a la vez** en toda
la cuenta, como el número de cajas abiertas en un supermercado.

Con un límite de 10, la **concurrencia reservada** no se puede usar: AWS exige dejar siempre al
menos 10 sin reservar, y reservar aunque sea 1 dejaría 9. Por eso el freno está en otro sitio:
`maximum_concurrency = 2` en el event source mapping. Se explica en [LAMBDA](LAMBDA.md#8-el-límite-de-10-de-la-cuenta).

### 3.3 La consola solo es accesible con el usuario raíz

| Vía | ¿Llega a la cuenta del proyecto? |
|---|---|
| Portal SSO | ❌ Lleva a la otra cuenta |
| El usuario IAM que usa Terraform | ❌ Solo tiene claves para la terminal, no contraseña de consola |
| Añadir la cuenta al SSO | ❌ La cuenta no pertenece a ninguna organización |
| **Usuario raíz** | ✅ La única vía |

Para mirar en un laboratorio personal es aceptable, siempre que el usuario raíz tenga MFA. Al
entrar hay que comprobar **siempre** dos cosas:

1. **Arriba a la derecha, el número de cuenta.**
2. **El selector de región: Europa (Irlanda), `eu-west-1`.** La consola suele abrirse en otra
   región, y entonces todo parece vacío.

## 4. PowerShell no es Bash

Windows PowerShell 5.1, el que trae Windows, no entiende parte de la sintaxis de Bash:

| Bash | PowerShell 5.1 |
|---|---|
| `cmd1 && cmd2` (solo si el primero va bien) | `cmd1; if ($?) { cmd2 }` |
| `cmd1; cmd2` (sin condición) | `cmd1; cmd2`: igual |
| `VAR=valor comando` | `$env:VAR = 'valor'` en una línea aparte |

La segunda diferencia es la que más confunde. En Bash, la variable puesta **delante** del
comando solo vale para esa ejecución. En PowerShell esa forma no existe: hay que asignarla
antes, y entonces vale para **toda la sesión de esa terminal**. Si abres una terminal nueva, se
pierde.

```powershell
cd infra; $env:AWS_PROFILE = 'testenforce-b'; terraform apply plan.tfplan
```

Con `Invoke-RestMethod`, las comillas simples de fuera hacen que PowerShell respete las dobles
del JSON de dentro:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:5080/resenyas -ContentType 'application/json' -Body '{"comentario":"Llegó roto","calificacion":1,"email":"a@ejemplo.com"}'
```

## 5. Trampas de Git Bash en Windows

Git Bash es otra terminal que se instala con Git. Tiene sus propias trampas, y conviene
conocerlas aunque no la uses:

| Síntoma | Causa | Solución |
|---|---|---|
| Python no encuentra `/tmp/fichero` que Bash acaba de crear | `/tmp` es una ruta de Git Bash; el Python de Windows no la entiende | Usar rutas de Windows, o `cygpath -w` |
| `aws logs ... /aws/lambda/...` falla con `failed to satisfy constraint` | Git Bash convierte cualquier argumento que empiece por `/` en una ruta de Windows | `MSYS_NO_PATHCONV=1` delante del comando |
| Salen `�` en lugar de tildes | La consola muestra la salida con otra codificación. **El contenido es correcto** | `PYTHONIOENCODING=utf-8` para Python |
| `LF will be replaced by CRLF` al hacer commit | Git en Windows convierte los saltos de línea al sacar los ficheros | Nada: es solo un aviso |

La de las tildes se comprobó dos veces: en la terminal salía `rese�a`, pero el correo que llegó
decía "reseña" perfectamente.

## 6. El estado de Terraform es compartido

El estado vive en el bucket de S3 que ya creó el bootstrap de TestEnforce, con una **clave
propia**: `workingevents/terraform.tfstate`. Un mismo bucket sirve para varios proyectos, cada
uno con su clave.

El nombre del bucket no está en el código porque contiene el número de cuenta. Se pasa al
inicializar:

```powershell
terraform init -backend-config="bucket=<bucket-de-estado>"
```
