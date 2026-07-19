# ============================================================================
#  Backend REMOTO del estado (terraform.tfstate) — Azure Storage Account.
#
#  Por qué: el .tfstate es el "mapa de recursos reales" (ver DESPLIEGUE.md,
#  sección "El estado"). Si vive solo en tu disco, nadie más — ni el pipeline
#  de CI/CD — puede leerlo o escribirlo, y lo pierdes si formateas la máquina.
#  Aquí vive en un Storage Account de Azure, con versionado activado (backup
#  automático de cada estado anterior) y locking automático (evita que dos
#  `apply` corran a la vez y corrompan el estado).
#
#  Este bloque va VACÍO a propósito ("configuración parcial de backend"): los
#  valores reales (uno por AMBIENTE) se pasan en `terraform init -backend-config=...`
#  — así el mismo código sirve para dev/test/prod, cada uno con su propio
#  archivo de estado (key), sin pisarse entre sí.
#
#  Backend ya aprovisionado (bootstrap, una sola vez, fuera de Terraform):
#    Resource Group   : battlecaos-tfstate-rg
#    Storage Account  : sttfstate67f1e1ad
#    Container        : tfstate
#
#  Uso LOCAL (ejemplo con el ambiente dev):
#    terraform init -backend-config=environments/dev.backend.hcl
#
#  Uso en CI: ver .github/workflows/terraform.yml (usa los mismos archivos
#  environments/{dev,test,prod}.backend.hcl).
# ============================================================================

terraform {
  backend "azurerm" {}
}
