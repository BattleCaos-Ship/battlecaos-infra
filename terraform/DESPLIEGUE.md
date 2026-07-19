# Despliegue de BattleCaos en Azure con Terraform + GitHub Actions

Infraestructura: **Azure Container Apps** — contenedores gestionados con **balanceador,
HTTPS y autoescalado integrados** (sin VMs ni Kubernetes que administrar).

```
Internet ──HTTPS──► gateway (N réplicas ← balanceo integrado de Azure)
                    auth · frontend (nginx)
                         │ red interna del Environment
                    kafka:9092 · redis-respaldo:6379 (internos)
                    room · game · chat · timer · bot · observability
                         │
   Externas: Upstash Redis (primario, doble escritura) + MongoDB Atlas (durable)
```

Las **2 bases de datos** siguen siendo las tuyas (Upstash + Atlas): se pasan como
secrets — nada de datos se migra. El respaldo de Redis corre dentro de Azure para
que la doble escritura funcione también en la nube.

Este documento cubre **dos caminos** para lo mismo:
- **§A — Manual** (desde tu PC, para aprender/depurar el flujo paso a paso).
- **§B — Automático** (GitHub Actions: Pull Request → plan → aprobación → apply).

Y tres secciones de referencia: **el estado** (§C), **los ambientes** (§D) y **las
imágenes Docker de cada microservicio** (§E).

---

## ✅ ESTADO ACTUAL — qué ya está hecho y qué sigue (checklist)

> Actualizado el 2026-07-14. Verificado contra Azure real, no solo contra el código.

### Ya hecho (no repetir)
- [x] Azure CLI + Terraform instalados, `az login` con la suscripción `Azure for Students`
- [x] Providers registrados: `Microsoft.App`, `Microsoft.OperationalInsights`,
      `Microsoft.ContainerRegistry`, `Microsoft.Storage`, `Microsoft.ManagedIdentity`
- [x] Backend remoto del estado creado y **verificado con un `init` real**: Storage
      Account `sttfstate67f1e1ad` (región `eastus2`), resource group
      `battlecaos-tfstate-rg`, container `tfstate`, versionado activo
- [x] Identidad OIDC para GitHub Actions creada y verificada: App Registration
      `battlecaos-infra-github-oidc` (Client ID `e08b1f1d-58d2-4eb1-936c-1f8dfcd932d6`),
      rol `Contributor` (suscripción) + `Storage Blob Data Contributor` (storage
      account), 4 credenciales federadas (`pull_request`, `environment:dev`,
      `environment:test`, `environment:production`) — todas para el repo
      `BattleCaos-Ship/battlecaos-infra`
- [x] `terraform validate` y un `terraform plan` REAL contra `dev` corridos con
      éxito (`14 to add, 0 to change, 0 to destroy`) — confirma que el backend,
      las variables por ambiente y los `.tfvars` funcionan juntos
- [x] MongoDB Atlas ya tiene *Network Access* en `0.0.0.0/0` (heredado de la
      configuración local — ya sirve también para Azure)
- [x] **Pipelines de imagen por microservicio (§E)**: workflow reusable
      `build-push-image.yml` en `battlecaos-infra` + un `build.yml` delgado en
      cada uno de los 9 repos + 9 credenciales federadas nuevas (verificadas,
      13 en total). YAML validado (`bash -n` de los bloques de shell incluido).
- [x] `terraform.tfvars` recreado y corregido en `battlecaos-infra/terraform/`
      (con el `subscription_id` real — el archivo viejo tenía un placeholder)

### 🚀 DEV DESPLEGADO (2026-07-14) — las 11 apps `Running` en Azure

| Recurso | URL / nombre |
|---|---|
| **Frontend (el juego)** | https://battlecaosdev-frontend.victoriousriver-7e24b629.eastus2.azurecontainerapps.io |
| Gateway (WebSocket) | https://battlecaosdev-gateway.victoriousriver-7e24b629.eastus2.azurecontainerapps.io |
| Auth (login) | https://battlecaosdev-auth.victoriousriver-7e24b629.eastus2.azurecontainerapps.io |
| ACR | `battlecaosdevacr52f56b.azurecr.io` |
| Internos | kafka, redis, room, game, chat, timer, bot, observability |

Notas del despliegue real (difieren del plan original):
- **`az acr build` NO sirve en Azure for Students** (`TasksOperationsNotAllowed`):
  las imágenes se construyen local con Docker y se suben con `docker push`
  (§A.4 ya está corregido; el workflow reusable de CI también).
- **`bitnami/kafka` ya no existe en Docker Hub** (Broadcom la retiró): se usa
  la oficial `apache/kafka:3.7.0` (main.tf ya actualizado, vars `KAFKA_*`).
- En esta máquina az CLI se colgaba por **WMI averiado** + **IPv6 roto en la
  red**: el despliegue usó un shim parcheado (ver "Problemas de esta máquina"
  al final de esta sección).

### Pendiente — EN ESTE ORDEN

1. **[TÚ] Google OAuth**: en Google Cloud Console → tu OAuth Client →
   *Authorized JavaScript origins* → agrega la URL del frontend (arriba).
   Sin esto el botón de "entrar con Google" fallará en el juego desplegado.
2. **[TÚ] Commitear y pushear** los cambios pendientes en los 9 repos de
   microservicios + `battlecaos-infra` (incluye los `.dockerignore` nuevos,
   el fix del workflow reusable y el `main.tf` con kafka oficial).
3. **[TÚ] En GitHub, en CADA uno de los 9 repos de microservicios**: agregar
   los secrets `AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`
   (y `GOOGLE_CLIENT_ID` solo en `battlecaos-frontend`) — ver la tabla exacta
   en §E. Sin esto, el build.yml de cada repo no puede autenticarse con Azure.
4. **[TÚ] En GitHub, en `battlecaos-infra`**: crear los 3 *Environments*
   (`dev`, `test`, `production`) y los 7 *Repository secrets* del pipeline de
   infraestructura — ver la lista exacta en §B.
5. Ambientes `test` y `prod`: repetir §A con sus `.tfvars` (o dejar que el
   pipeline de GitHub Actions lo haga tras el paso 4).

### ⚠️ Problemas de ESTA máquina (para despliegues manuales futuros)

Dos averías locales hacían que az/terraform se "colgaran para siempre":
1. **WMI averiado**: cualquier `platform.uname()` de Python (que az usa) se
   congela. Arreglo permanente (PowerShell como admin):
   `winmgmt /verifyrepository` y si sale inconsistente `winmgmt /salvagerepository`.
2. **IPv6 roto en la red**: los SYN a direcciones IPv6 se pierden sin respuesta;
   Python espera el timeout completo (el navegador no, por happy-eyeballs).
El despliegue se hizo con un **shim del az CLI** (clon de python + parche que
fuerza IPv4 y evita WMI). Si az vuelve a colgarse en una terminal normal, esa
es la causa — no es Azure ni el proyecto.

---

## §A. Despliegue MANUAL (desde tu PC)

### 0. Requisitos (una sola vez) — ✅ HECHO

1. **Azure CLI**: `winget install Microsoft.AzureCLI`
2. **Terraform**: `winget install Hashicorp.Terraform`
3. Sesión: `az login` (elige la suscripción de Azure for Students si aplica)
4. Registrar los providers (primera vez en la suscripción):
   ```powershell
   az provider register -n Microsoft.App
   az provider register -n Microsoft.OperationalInsights
   az provider register -n Microsoft.ContainerRegistry
   az provider register -n Microsoft.Storage
   az provider register -n Microsoft.ManagedIdentity
   ```
   > Nota: en algunas suscripciones de Azure for Students la región `eastus` está
   > bloqueada por política ("best available regions"). Este proyecto usa `eastus2`
   > por defecto — confirmado funcional.

### 1. Configurar los secrets (uso local) — ⚠️ REPETIR (ver checklist arriba, punto 4)

```powershell
cd terraform
copy terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars   # ← rellena redis_url, mongo_url, jwt_secret, google_client_id
```
> `terraform.tfvars` está en `.gitignore` — jamás se sube al repo. El `subscription_id`
> ya no hace falta ponerlo ahí (queda fuera de las vars de la app; se usa vía `az login`).

### 2. Inicializar contra el backend REMOTO (elige un ambiente) — ⚠️ REPETIR (punto 5)

El estado NO es local — vive en un Storage Account de Azure (§C). Para trabajar
manualmente contra, por ejemplo, `dev`:

```powershell
terraform init -backend-config=environments/dev.backend.hcl
```

### 3. Crear el registro de imágenes (primera pasada parcial) — 👉 SIGUES AQUÍ (punto 6)

```powershell
terraform apply -var-file=environments/dev.tfvars -target=azurerm_container_registry.acr
$ACR = terraform output -raw acr_name
```

### 4. Construir y subir las imágenes de backend

> ⚠️ **`az acr build` NO funciona en Azure for Students** (error
> `TasksOperationsNotAllowed`: Microsoft bloquea ACR Tasks en suscripciones de
> estudiante). Se construye **local con Docker** y se sube con push:

```powershell
cd ..
az acr credential show --name $ACR --query "passwords[0].value" -o tsv |
  docker login "$ACR.azurecr.io" -u $ACR --password-stdin
foreach ($s in 'gateway','auth','room','game','chat','timer','bot','observability') {
  docker build -t "$ACR.azurecr.io/battlecaos-${s}:dev" "battlecaos-$s"
  docker push  "$ACR.azurecr.io/battlecaos-${s}:dev"
}
```

> Cuando §E (pipelines por microservicio) esté listo, este paso se vuelve
> automático en cada push a cada repo — pero para la primera vez, hazlo manual.

### 5. Desplegar toda la infraestructura del ambiente

```powershell
cd terraform
terraform apply -var-file=environments/dev.tfvars
terraform output   # ← anota gateway_url y auth_url
```

### 6. Construir el frontend con las URLs reales y desplegarlo

```powershell
cd ..
$GW   = terraform -chdir=terraform output -raw gateway_url
$AUTH = terraform -chdir=terraform output -raw auth_url
docker build -t "$ACR.azurecr.io/battlecaos-frontend:dev" `
  --build-arg VITE_GATEWAY_URL=$GW `
  --build-arg VITE_AUTH_URL=$AUTH `
  --build-arg VITE_GOOGLE_CLIENT_ID=TU_CLIENT_ID.apps.googleusercontent.com `
  battlecaos-frontend
docker push "$ACR.azurecr.io/battlecaos-frontend:dev"

cd terraform
terraform apply -var-file=environments/dev.tfvars -var="deploy_frontend=true"
terraform output frontend_url
```

### 7. Últimos ajustes

1. **Google OAuth**: Google Cloud Console → tu OAuth Client → *Authorized JavaScript
   origins* → agrega la `frontend_url`.
2. **Atlas**: *Network Access* debe permitir `0.0.0.0/0` — ✅ ya configurado.
3. Verifica salud: abre `gateway_url/health` y `auth_url/health` — deben responder
   con `redis: ok` y `mongo: ok`.

### Repetir para test/prod

Igual que arriba, pero usando `environments/test.backend.hcl`+`environments/test.tfvars`
o `environments/prod.backend.hcl`+`environments/prod.tfvars`. Cada ambiente tiene su
propio `prefix` (nombres de recursos distintos) y su propio archivo de estado — no se pisan.

---

## §B. Despliegue AUTOMÁTICO (GitHub Actions)

El pipeline (`.github/workflows/terraform.yml`) implementa exactamente:

```
Pull Request → fmt/validate (calidad) → plan (impacto visible, comentado en el PR)
             → approval (Required reviewers de GitHub) → apply (dev → test → prod)
```

### Configuración ÚNICA — ✅ lo mío ya está hecho, falta lo tuyo en GitHub

**Ya aprovisionado por mí vía Azure CLI** (no hace falta repetirlo):
- Backend remoto: Storage Account `sttfstate67f1e1ad` en `battlecaos-tfstate-rg` (eastus2), container `tfstate`, versionado activo.
- Identidad OIDC: App Registration `battlecaos-infra-github-oidc`, con:
  - Rol `Contributor` a nivel de suscripción (pragmático para un sandbox de curso —
    los resource groups de dev/test/prod aún no existían para acotar el scope antes
    del primer apply; en una empresa real se acotaría por resource group).
  - Rol `Storage Blob Data Contributor` sobre el storage account del backend.
  - 4 credenciales federadas (sin contraseñas ni secrets — GitHub prueba su identidad
    con un token OIDC de corta duración): una para Pull Requests, y una por cada
    GitHub Environment (`dev`, `test`, `production`).

**Pendiente — hazlo tú en GitHub** (Settings del repo `battlecaos-infra`):

1. **Settings → Environments** → crea 3 ambientes con estos nombres EXACTOS
   (coinciden con las credenciales federadas ya creadas):
   - `dev` — sin protección (se despliega solo al hacer merge a `main`).
   - `test` — activa **Required reviewers** (tú mismo u otro compañero).
   - `production` — activa **Required reviewers** (obligatorio: aquí está la
     "aprobación humana" de tu diagrama).

2. **Settings → Secrets and variables → Actions → Repository secrets** — agrega:
   | Nombre | Valor |
   |---|---|
   | `AZURE_CLIENT_ID` | `e08b1f1d-58d2-4eb1-936c-1f8dfcd932d6` |
   | `AZURE_TENANT_ID` | `50640584-2a40-4216-a84b-9b3ee0f3f6cf` |
   | `AZURE_SUBSCRIPTION_ID` | `fb171b29-8bbd-4355-94e6-8d0fdf2f5199` |
   | `REDIS_URL` | tu connection string de Upstash (de `battlecaos-gateway/.env`) |
   | `MONGO_URL` | tu connection string de Atlas (de `battlecaos-auth/.env`) |
   | `JWT_SECRET` | tu JWT_SECRET (de `battlecaos-gateway/.env`) |
   | `GOOGLE_CLIENT_ID` | tu Client ID de Google OAuth |

   > Los 3 `AZURE_*` no son secretos sensibles (OIDC no usa contraseña), pero
   > guardarlos como secret no hace daño. Los otros 4 SÍ son sensibles de verdad.

3. **Primera vez**: como el frontend necesita 2 pasadas (§A.6), el workflow por
   defecto NO lo despliega (`deploy_frontend=false` en cada `environments/*.tfvars`).
   Tras el primer `apply` exitoso de cada ambiente, construye la imagen del frontend
   con `docker build` + `push` (igual que en §A.6) y cambia `deploy_frontend = true`
   en el `.tfvars` de ese ambiente en un nuevo PR.

### Cómo se usa, en la práctica

1. Editas algo en `terraform/*.tf` → abres un **Pull Request** contra `main`.
2. El workflow corre `fmt` + `validate` + `plan` contra `dev`, y **comenta el plan
   completo en el PR** — así el equipo ve el impacto antes de aprobar el PR de código.
3. Al hacer **merge a `main`**, se dispara la promoción: `deploy-dev` (automático) →
   `deploy-test` (pausado hasta que un revisor apruebe en GitHub) → `deploy-prod`
   (pausado igual, la última compuerta antes de tocar producción).
4. Cada job hace `plan` + `apply` en el mismo paso — se aplica exactamente el plan
   recién calculado para ESE ambiente (sin usar un plan viejo de otro ambiente).

### Destruir (controlado)

`.github/workflows/terraform-destroy.yml` — disparo manual desde la pestaña *Actions*
de GitHub. Pide el ambiente y una confirmación escrita (`destruir-dev`, `destruir-test`,
`destruir-prod`) antes de proceder, y pasa por el mismo Environment con su aprobación.

---

## §C. El estado (`terraform.tfstate`)

| Concepto | Qué es | Dónde vive aquí |
|---|---|---|
| **Código HCL** (`main.tf`, `apps.tf`...) | El estado **deseado** — lo que debería existir | En este repo Git, versionado |
| **`terraform.tfstate`** | El **mapa** de qué recursos reales corresponden a qué bloques de tu código (IDs, atributos) | Azure Storage Account `sttfstate67f1e1ad`, container `tfstate` — NO en tu disco |
| **Infraestructura real en Azure** | Lo que **de verdad** existe y cuesta dinero | Tu suscripción `Azure for Students` |

`terraform plan` compara los 3: código deseado vs. estado registrado vs. (opcionalmente)
un refresh de la realidad — y te muestra la diferencia antes de tocar nada.

**Por qué remoto y no en tu disco:** si el estado viviera solo en tu PC, GitHub Actions
no podría leerlo (no sabría qué existe ya) y cada corrida de CI recrearía todo desde cero
o chocaría con lo existente. El backend remoto además **bloquea** el estado mientras
alguien hace `apply` (evita que dos ejecuciones se pisen — lo comprobamos en vivo: un
`terraform force-unlock` fue necesario tras un intento interrumpido) y guarda versiones
anteriores (puedes recuperarte de un `apply` erróneo).

## §D. Ambientes (Dev / Test / Prod)

Un único código (`main.tf`/`apps.tf`) sirve para los 3 ambientes — lo que cambia es:

| | Dev | Test | Prod |
|---|---|---|---|
| Archivo de variables | `environments/dev.tfvars` | `environments/test.tfvars` | `environments/prod.tfvars` |
| Archivo de estado (`key` del backend) | `dev.terraform.tfstate` | `test.terraform.tfstate` | `prod.terraform.tfstate` |
| Prefijo de recursos | `battlecaosdev` | `battlecaostest` | `battlecaosprod` |
| Réplicas del gateway | 1 | 2 | 3 |
| Aprobación para desplegar | No (automático) | Sí (Required reviewers) | Sí (Required reviewers) |

Los 3 ambientes son **infraestructuras Azure completamente separadas** (resource
group, ACR, Container Apps propios) pero **comparten** el mismo Upstash y el mismo
Atlas (una sola base de datos externa para los 3) — suficiente para un proyecto de
curso; en una empresa real cada ambiente tendría también su propia base de datos.

## §E. Imágenes Docker por microservicio (pipeline independiente por repo) — ✅ LISTO

**Decisión de arquitectura**: cada uno de los 9 repos de microservicios
(`battlecaos-gateway`, `-auth`, `-room`, `-game`, `-chat`, `-timer`, `-bot`,
`-observability`, `-frontend`) tiene **su propio pipeline independiente** de
build+push de imagen — NO un pipeline centralizado que orqueste los 9 a la vez.
Es la práctica estándar en microservicios: cada servicio se construye y despliega
sin depender de los demás.

Para evitar copiar 9 veces el mismo YAML, la lógica de "construir la imagen Docker
y subirla a ACR" vive **una sola vez** como *workflow reusable* en este repo:
`.github/workflows/build-push-image.yml`. Cada uno de los 9 repos tiene solo un
archivo delgado (`build.yml`) de ~10 líneas que lo invoca con
`uses: BattleCaos-Ship/battlecaos-infra/.github/workflows/build-push-image.yml@main`.

### Cómo funciona

1. Push a `main` de, por ejemplo, `battlecaos-game` → dispara SOLO el pipeline
   de `game` (ninguno de los otros 8 se entera).
2. Ese pipeline hace login a Azure vía OIDC (credencial federada propia de ese
   repo — no reutiliza la de PR/ambientes de `battlecaos-infra`, aunque comparte
   la misma identidad/App Registration) y resuelve el ACR del ambiente **por el
   nombre del resource group** (`battlecaosdev-rg`, determinístico), sin
   necesitar leer el estado de Terraform desde otro repo.
3. `docker build` compila la imagen **en el runner** y `docker push` la sube como
   `battlecaos-<servicio>:<ambiente>` (ej. `battlecaos-game:dev`). (Antes usaba
   `az acr build`/ACR Tasks, pero Azure for Students lo bloquea —
   `TasksOperationsNotAllowed`.)
4. **Caso especial — frontend**: además resuelve las URLs reales de `gateway`/
   `auth` consultando sus Container Apps ya desplegados (mismo truco de nombre
   determinístico) y las pasa como build-args de Vite automáticamente. Por eso
   el frontend debe construirse **después** de que gateway/auth ya estén
   desplegados en ese ambiente.
5. También se puede disparar a mano (`workflow_dispatch`) eligiendo ambiente —
   útil para promover una imagen a `test`/`prod` sin esperar un nuevo push.

### Identidad usada

Reutiliza la MISMA App Registration `battlecaos-infra-github-oidc`
(`e08b1f1d-58d2-4eb1-936c-1f8dfcd932d6`) que ya tiene `Contributor` a nivel de
suscripción — no se crearon 9 identidades nuevas, solo **9 credenciales federadas
adicionales** (una por repo), con subject `repo:BattleCaos-Ship/battlecaos-<servicio>:ref:refs/heads/main`.
Verificadas con `az ad app federated-credential list` — 13 en total (4 de
`battlecaos-infra` + 9 de microservicios).

### Pendiente — hazlo tú en GitHub, en CADA uno de los 9 repos

**Settings → Secrets and variables → Actions → Repository secrets**, agrega:

| Nombre | Valor | ¿En cuáles repos? |
|---|---|---|
| `AZURE_CLIENT_ID` | `e08b1f1d-58d2-4eb1-936c-1f8dfcd932d6` | Los 9 |
| `AZURE_TENANT_ID` | `50640584-2a40-4216-a84b-9b3ee0f3f6cf` | Los 9 |
| `AZURE_SUBSCRIPTION_ID` | `fb171b29-8bbd-4355-94e6-8d0fdf2f5199` | Los 9 |
| `GOOGLE_CLIENT_ID` | tu Client ID de Google OAuth | Solo `battlecaos-frontend` |

> Sí, es repetir los 3 `AZURE_*` en cada repo — es una limitación real de GitHub
> (`secrets: inherit` solo hereda los secrets del repo que LLAMA al workflow
> reusable, no los del repo donde vive la lógica). Para 9 repos son ~27 clics,
> una vez.

### Archivos de este mecanismo

| Archivo | Repo |
|---|---|
| `.github/workflows/build-push-image.yml` | `battlecaos-infra` (la lógica, una sola vez) |
| `.github/workflows/build.yml` | Cada uno de los 9 repos (invocación delgada) |

---

## Comandos de referencia (init / validate / plan / apply / destroy)

```powershell
terraform init -backend-config=environments/<env>.backend.hcl   # descarga providers + conecta al backend remoto
terraform validate                                                # revisa sintaxis y coherencia interna
terraform plan  -var-file=environments/<env>.tfvars               # muestra qué CAMBIARÍA, sin tocar nada
terraform apply -var-file=environments/<env>.tfvars               # ejecuta esos cambios (pide confirmación)
terraform destroy -var-file=environments/<env>.tfvars             # elimina TODO lo de ese ambiente (controlado)
```

## Costos y apagado

- Con Azure for Students ($100 de crédito): cada ambiente cuesta aprox. **$15-60/mes**
  encendido 24/7 según sus réplicas (dev el más barato, prod el más caro).
- Usa `terraform-destroy.yml` (o `terraform destroy` manual) para apagar un ambiente
  que no estés usando — las URLs cambian al volver a crear.

## Problemas conocidos

| Síntoma | Causa/solución |
|---|---|
| `SubscriptionNotFound` al crear un recurso recién registrado un provider | Transitorio tras `az provider register` — reintenta a los 30-60s |
| `RequestDisallowedByAzure` (política de regiones) | Tu suscripción no permite ese tipo de recurso en `eastus` — usa `eastus2` (ya es el default) |
| `Error acquiring the state lock` / `state blob is already locked` | Una corrida anterior se interrumpió sin liberar el lock (nos pasó una vez). Verifica que NADA esté corriendo de verdad, luego: `terraform force-unlock -force "<Lock ID del mensaje>"` |
| gateway no recibe eventos | Kafka tardó en arrancar: `az containerapp revision restart` del gateway, o revisa logs de `<prefix>-kafka` |
| `mongo: down` en /health | Atlas Network Access sin `0.0.0.0/0`, o `mongo_url` mal pegada |
| Google login falla | Falta la `frontend_url` de ESE ambiente en los orígenes autorizados del OAuth Client |
| ACR name taken | El nombre del ACR es global — cambia `prefix` en el `.tfvars` del ambiente |
| El job de GitHub Actions se queda "esperando" | Normal si `test`/`production` tienen Required reviewers — alguien debe aprobar en la pestaña *Actions* del PR/run |
| PowerShell: `terraform ... 2>&1 \| Select-Object` da "Too many command line arguments" | Evita combinar pipes con redirección en la misma línea al llamar terraform.exe desde este entorno — ejecuta el comando solo, sin pipe |
