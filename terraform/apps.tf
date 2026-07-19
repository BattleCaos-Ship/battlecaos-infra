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
    { name = "KAFKA_BROKER", value = local.kafka_bootstrap, secret = null },
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
    # Chat de voz (WebRTC P2P): solo orquesta el canal (Kafka/Redis), no transporta audio.
    # VOICE_ICE_SERVERS opcional (JSON con TURN); sin él usa STUN por defecto.
    voice-channel = []
  }

  # Servicios que es SEGURO escalar horizontalmente por lag de Kafka: consumen comandos
  # keyed por `codigo` de sala → distintas salas se reparten entre réplicas sin desorden,
  # y una misma sala sigue procesándose en orden en una sola partición. `timer` (leader
  # election, ve todo el stream), `bot` (fan-out) y `observability` (agrega global) NO
  # se escalan así — quedan en 1 réplica.
  scalable = {
    game          = "cmd.game"
    room          = "cmd.room"
    chat          = "cmd.chat"
    voice-channel = "cmd.voice"
  }

  # Puerto donde cada servicio interno expone /health y /metrics (observability.js).
  obs_port = 9100
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
    # AUTOESCALADO por lag de Kafka (KEDA) en los servicios seguros de escalar: min 1
    # (mismo costo en reposo que antes) / max 3 (sube solo bajo carga). El resto: 1 fija.
    min_replicas = 1
    max_replicas = contains(keys(local.scalable), each.key) ? 3 : 1

    # Regla de escalado KEDA por lag del consumer group de Kafka. Solo para los servicios
    # de local.scalable; sube una réplica por cada `lagThreshold` mensajes acumulados.
    dynamic "custom_scale_rule" {
      for_each = contains(keys(local.scalable), each.key) ? [1] : []
      content {
        name             = "kafka-lag"
        custom_rule_type = "kafka"
        # Kafka interno PLAINTEXT sin auth → sasl/tls deshabilitados en metadata (sin
        # bloque authentication, que exigiría un secret de TriggerAuthentication).
        metadata = {
          bootstrapServers   = local.kafka_bootstrap
          consumerGroup      = "${each.key == "voice-channel" ? "voice" : each.key}-group"
          topic              = local.scalable[each.key]
          lagThreshold       = "50"
          offsetResetPolicy  = "latest"
          allowIdleConsumers = "true"
          sasl               = "none"
          tls                = "disable"
        }
      }
    }

    container {
      name   = each.key
      image  = "${local.registry_server}/battlecaos-${each.key}:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      # Nombre del servicio (prefijo de métricas) y puerto de observabilidad.
      env {
        name  = "SERVICE_NAME"
        value = each.key
      }
      env {
        name  = "OBS_PORT"
        value = tostring(local.obs_port)
      }

      dynamic "env" {
        for_each = concat(local.common_env, each.value)
        content {
          name        = env.value.name
          value       = env.value.value
          secret_name = env.value.secret
        }
      }

      # Liveness probe sobre /health: si el proceso se cuelga (no solo si muere), Azure
      # reemplaza la réplica. Usa la redundancia de Redis: /health da 200 mientras haya
      # al menos un nodo vivo.
      liveness_probe {
        transport = "HTTP"
        port      = local.obs_port
        path      = "/health"
        interval_seconds  = 15
        timeout           = 3
        failure_count_threshold = 3
      }
      readiness_probe {
        transport = "HTTP"
        port      = local.obs_port
        path      = "/health"
        interval_seconds  = 10
        timeout           = 3
        failure_count_threshold = 3
      }
    }
  }
}

# ── GATEWAY (punto de entrada WebSocket, 3 réplicas balanceadas) ──────────────
resource "azurerm_container_app" "gateway" {
  name                         = "${var.prefix}-gateway"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  # MULTIPLE revision mode → una revisión nueva NACE con 0% de tráfico (el primitivo de canary):
  # se despliega "a oscuras", se le manda un % pequeño, se observa y se promueve o se revierte.
  # En Single mode, cada deploy iba a 100% al instante (un deploy malo = caída total inmediata).
  revision_mode = "Multiple"

  ingress {
    external_enabled = true
    target_port      = 3000
    transport        = "auto" # HTTP + upgrade a WebSocket
    # Valor inicial (para crear el recurso desde cero). En operación el SPLIT de tráfico lo
    # gobierna el pipeline de canary vía az (por peso de revisión), no Terraform: por eso
    # 'traffic_weight' está en ignore_changes abajo → Terraform NO revierte un canary en curso.
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  # El split de tráfico es responsabilidad del pipeline de canary (tools/deploy/canary.ps1),
  # no de Terraform. Sin esto, cada `terraform apply` forzaría 'latest=100%' y anularía el
  # canary (o la revisión estable elegida) que el pipeline haya dejado sirviendo.
  lifecycle {
    ignore_changes = [ingress[0].traffic_weight]
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

    # AUTOESCALADO explícito por CONEXIONES CONCURRENTES (no por CPU). El gateway sirve
    # WebSockets de larga vida: la señal correcta de saturación es cuántos sockets sostiene
    # cada réplica, no su CPU (que puede estar baja mientras miles de conexiones esperan). Sin
    # esta regla, Container Apps usaba el escalador HTTP por defecto (10 conc/réplica) — demasiado
    # agresivo para WS. Aquí sube una réplica por cada `gateway_scale_concurrency` conexiones.
    http_scale_rule {
      name                = "sockets-concurrentes"
      concurrent_requests = tostring(var.gateway_scale_concurrency)
    }

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
        value = local.kafka_bootstrap
      }
      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }
      env {
        name  = "CLIENT_ORIGIN"
        value = "*"
      }

      # Probes sobre /health (puerto 3000, el mismo del ingress WebSocket). /health ahora
      # verifica Redis Y la salud del consumer de Kafka: si el consumer se cuelga (deja de
      # entregar broadcasts a los clientes), devuelve 503 y Azure reinicia la réplica. La
      # readiness saca la réplica del balanceador mientras arranca o si queda degradada.
      liveness_probe {
        transport               = "HTTP"
        port                    = 3000
        path                    = "/health"
        interval_seconds        = 15
        timeout                 = 3
        failure_count_threshold = 3
      }
      readiness_probe {
        transport               = "HTTP"
        port                    = 3000
        path                    = "/health"
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 3
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

      # Probes sobre /health (puerto 3001). auth no consume Kafka → basta con el ping a Redis.
      liveness_probe {
        transport               = "HTTP"
        port                    = 3001
        path                    = "/health"
        interval_seconds        = 15
        timeout                 = 3
        failure_count_threshold = 3
      }
      readiness_probe {
        transport               = "HTTP"
        port                    = 3001
        path                    = "/health"
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 3
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
