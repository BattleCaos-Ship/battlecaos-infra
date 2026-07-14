# ── Identidad / ubicación ─────────────────────────────────────────────────────

variable "subscription_id" {
  description = "ID de tu suscripción de Azure (az account show --query id -o tsv)"
  type        = string
}

variable "location" {
  description = "Región de Azure (eastus2 confirmada como disponible en esta suscripción — eastus está bloqueada por política de Azure for Students)"
  type        = string
  default     = "eastus2"
}

variable "prefix" {
  description = "Prefijo de nombres (solo minúsculas y números — lo exige ACR). Debe ser distinto por ambiente (dev/test/prod) para no colisionar nombres de recursos."
  type        = string
  default     = "battlecaos"
}

variable "environment" {
  description = "Ambiente lógico: dev | test | prod. Se usa como etiqueta y en el nombre de algunos recursos."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment debe ser 'dev', 'test' o 'prod'."
  }
}

# ── Secrets (van en terraform.tfvars — NUNCA al repo) ─────────────────────────

variable "redis_url" {
  description = "Connection string de Upstash Redis (rediss://default:...@....upstash.io:6379)"
  type        = string
  sensitive   = true
}

variable "mongo_url" {
  description = "Connection string de MongoDB Atlas (mongodb+srv://usuario:...@cluster...)"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "Secreto JWT compartido por auth (firma) y gateway (verificación) — mínimo 32 caracteres"
  type        = string
  sensitive   = true
}

variable "google_client_id" {
  description = "Client ID de Google OAuth (xxxx.apps.googleusercontent.com)"
  type        = string
}

# ── Escalado / despliegue ──────────────────────────────────────────────────────

variable "gateway_replicas" {
  description = "Réplicas del gateway (el balanceador integrado de Container Apps reparte entre ellas)"
  type        = number
  default     = 3
}

variable "image_tag" {
  description = "Tag de las imágenes en ACR"
  type        = string
  default     = "v1"
}

variable "deploy_frontend" {
  description = "Desplegar el frontend (activar en la SEGUNDA pasada, cuando su imagen ya existe en ACR)"
  type        = bool
  default     = false
}
