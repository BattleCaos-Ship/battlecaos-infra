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
  description = "Réplicas MÍNIMAS del gateway (el balanceador integrado de Container Apps reparte entre ellas)"
  type        = number
  default     = 3
}

variable "gateway_scale_concurrency" {
  description = "Conexiones concurrentes por réplica del gateway que disparan un scale-out (métrica WebSocket, no CPU)"
  type        = number
  default     = 100
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

# ── Ronda B de disponibilidad (OPT-IN — cambios DESTRUCTIVOS, ver deploy/HA-RONDA-B-APPLY.md) ──

variable "enable_zone_redundancy" {
  description = <<-EOT
    Activa la redundancia de ZONA del Container Apps Environment. ⚠️ DESTRUCTIVO: `zone_redundant`
    es inmutable → cambiarlo RECREA el environment y TODAS las apps que viven en él. Además exige
    una subred de infraestructura (VNet) → este flag también crea la VNet/subred. Solo en ventana
    de mantenimiento. Por defecto false (sin cambios respecto al sandbox actual).
  EOT
  type        = bool
  default     = false
}

variable "kafka_brokers" {
  description = <<-EOT
    Nº de brokers de Kafka. 1 = broker único actual (recurso azurerm_container_app.kafka en main.tf).
    3 = clúster KRaft de 3 brokers (kafka-cluster.tf) con Azure Files por broker y RF=3 → tolera la
    caída de 1 broker. ⚠️ Migrar de 1→3 requiere recrear el bus y subir el RF de los topics
    existentes (destructivo). Triplica el uso de CPU/mem. Ver deploy/HA-RONDA-B-APPLY.md.
  EOT
  type        = number
  default     = 1
  validation {
    condition     = var.kafka_brokers == 1 || var.kafka_brokers == 3
    error_message = "kafka_brokers debe ser 1 (broker único) o 3 (clúster con tolerancia a fallos)."
  }
}
