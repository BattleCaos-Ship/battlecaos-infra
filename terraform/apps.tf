# ============================================================================
#  Aplicaciones de BattleCaos como Container Apps.
#
#  BALANCEO: el gateway es UNA app con N réplicas (var.gateway_replicas = 3).
#  El ingress de Container Apps trae el balanceador integrado que reparte las
#  conexiones entre réplicas. No hace falta sticky sessions porque el frontend
#  conecta por WebSocket directo (sin handshake de long-polling), y el fan-out
#  de broadcasts entre réplicas ya lo resuelve el consumer-group-por-instancia
#  (cada réplica usa CONTAINER_APP_REPLICA_NAME como INSTANCE_ID).
# ============================================================================

locals {
  registry_server = azurerm_container_registry.acr.login_server

  # Variables comunes a todos los servicios de backend.
  common_env = [
    { name = "KAFKA_BROKER", value = "${var.prefix}-kafka:9092", secret = null },
    # Primario RÁPIDO = Redis interno de Azure (co-ubicado, ~1ms). Respaldo DURABLE = Upstash
    # (réplica ASÍNCRONA en segundo plano). Así la ruta caliente no espera al Upstash remoto.
    { name = "REDIS_URL", value = "redis://${var.prefix}-redis:6379", secret = null },
    { name = "REDIS_FALLBACK_URL", value = null, secret = "redis-url" },
    { name = "LOG_LEVEL", value = "info", secret = null },
  ]

  # Servicios de dominio SIN ingress (solo hablan Kafka/Redis) + sus envs extra.
  backends = {
    room          = []
    game          = []
    chat          = []
    timer         = []
    bot           = []
    observability = [{ name = "MONGO_URL", value = null, secret = "mongo-url" }]
  }
}

# ── Servicios de dominio (room, game, chat, timer, bot, observability) ────────
resource "azurerm_container_app" "backend" {
  for_each = local.backends

  name                         = "${var.prefix}-${each.key}"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  secret {
    name  = "redis-url"
    value = var.redis_url
  }
  secret {
    name  = "mongo-url"
    value = var.mongo_url
  }
  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  registry {
    server               = local.registry_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  template {
    # 1 réplica por servicio: los topics se auto-crean con 1 partición, así que más
    # réplicas del mismo consumer group no reciben trabajo extra. Para escalar de
    # verdad: subir particiones de cmd.game y aquí min/max_replicas.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = each.key
      image  = "${local.registry_server}/battlecaos-${each.key}:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = concat(local.common_env, each.value)
        content {
          name        = env.value.name
          value       = env.value.value
          secret_name = env.value.secret
        }
      }
    }
  }
}

# ── GATEWAY (punto de entrada WebSocket, 3 réplicas balanceadas) ──────────────
resource "azurerm_container_app" "gateway" {
  name                         = "${var.prefix}-gateway"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  ingress {
    external_enabled = true
    target_port      = 3000
    transport        = "auto" # HTTP + upgrade a WebSocket
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  secret {
    name  = "redis-url"
    value = var.redis_url
  }
  secret {
    name  = "jwt-secret"
    value = var.jwt_secret
  }
  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  registry {
    server               = local.registry_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  template {
    min_replicas = var.gateway_replicas # ← los "3 gateways"
    max_replicas = var.gateway_replicas + 2

    container {
      name   = "gateway"
      image  = "${local.registry_server}/battlecaos-gateway:${var.image_tag}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "GATEWAY_PORT"
        value = "3000"
      }
      env {
        name  = "REDIS_URL"
        value = "redis://${var.prefix}-redis:6379" # primario rápido (interno)
      }
      env {
        name        = "REDIS_FALLBACK_URL"
        secret_name = "redis-url" # respaldo durable (Upstash, réplica asíncrona)
      }
      env {
        name  = "KAFKA_BROKER"
        value = "${var.prefix}-kafka:9092"
      }
      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }
      env {
        name  = "CLIENT_ORIGIN"
        value = "*"
      }
    }
  }
}

# ── AUTH (HTTP: login Google + registro local contra Atlas) ──────────────────
resource "azurerm_container_app" "auth" {
  name                         = "${var.prefix}-auth"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  ingress {
    external_enabled = true
    target_port      = 3001
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  secret {
    name  = "redis-url"
    value = var.redis_url
  }
  secret {
    name  = "mongo-url"
    value = var.mongo_url
  }
  secret {
    name  = "jwt-secret"
    value = var.jwt_secret
  }
  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  registry {
    server               = local.registry_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  template {
    min_replicas = 1
    max_replicas = 2

    container {
      name   = "auth"
      image  = "${local.registry_server}/battlecaos-auth:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "AUTH_PORT"
        value = "3001"
      }
      env {
        name  = "REDIS_URL"
        value = "redis://${var.prefix}-redis:6379" # primario rápido (interno)
      }
      env {
        name        = "REDIS_FALLBACK_URL"
        secret_name = "redis-url" # respaldo durable (Upstash, réplica asíncrona)
      }
      env {
        name        = "MONGO_URL"
        secret_name = "mongo-url"
      }
      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }
      env {
        name  = "GOOGLE_CLIENT_ID"
        value = var.google_client_id
      }
      env {
        name  = "CLIENT_ORIGIN"
        value = "*"
      }
    }
  }
}

# ── FRONTEND (nginx con el build de Vite) — segunda pasada ───────────────────
# Se activa con -var="deploy_frontend=true" DESPUÉS de construir su imagen,
# porque el build necesita hornear las URLs reales de gateway y auth.
resource "azurerm_container_app" "frontend" {
  count = var.deploy_frontend ? 1 : 0

  name                         = "${var.prefix}-frontend"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  ingress {
    external_enabled = true
    target_port      = 80
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  registry {
    server               = local.registry_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  template {
    min_replicas = 1
    max_replicas = 2

    container {
      name   = "frontend"
      image  = "${local.registry_server}/battlecaos-frontend:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }
}
