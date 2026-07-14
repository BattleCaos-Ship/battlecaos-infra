# ============================================================================
#  BattleCaos en Azure — infraestructura base (Fase de despliegue).
#
#  Arquitectura (Azure Container Apps = contenedores gestionados con balanceo,
#  autoescalado y HTTPS integrados — sin administrar VMs ni Kubernetes):
#
#      Internet ──► gateway (Container App, 3 réplicas ← balanceo integrado)
#                   auth    (Container App, HTTPS)
#                   frontend (Container App nginx, HTTPS)
#                        │  (red interna del Environment)
#                   kafka (interno TCP :9092)   redis-respaldo (interno TCP :6379)
#                   room · game · chat · timer · bot · observability (internos)
#                        │
#      Externo: Upstash Redis (primario, doble escritura) + MongoDB Atlas (durable)
# ============================================================================

resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = { environment = var.environment, project = "battlecaos" }
}

# Registro de imágenes. admin_enabled: las Container Apps se autentican con
# usuario/contraseña del registro (suficiente para el curso; en prod: managed identity).
resource "azurerm_container_registry" "acr" {
  name                = "${var.prefix}acr${substr(md5(azurerm_resource_group.rg.id), 0, 6)}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

resource "azurerm_log_analytics_workspace" "logs" {
  name                = "${var.prefix}-logs"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# El "Environment" = la red compartida donde viven todas las apps. Dentro de él,
# las apps se resuelven entre sí por nombre (battlecaos-kafka, battlecaos-redis...).
resource "azurerm_container_app_environment" "env" {
  name                       = "${var.prefix}-env"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
}

# ── Kafka (interno) ───────────────────────────────────────────────────────────
# Un broker KRaft (sin zookeeper) dentro del Environment. Los servicios lo alcanzan
# como battlecaos-kafka:9092. Nota: almacenamiento efímero — si el contenedor se
# reinicia se pierden mensajes en vuelo; aceptable porque los topics transportan
# comandos/eventos transitorios (el ESTADO vive en Redis/Atlas).
resource "azurerm_container_app" "kafka" {
  name                         = "${var.prefix}-kafka"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  ingress {
    external_enabled = false
    target_port      = 9092
    exposed_port     = 9092
    transport        = "tcp"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1 # broker con identidad: NO se escala horizontalmente así

    container {
      name   = "kafka"
      image  = "bitnami/kafka:3.7"
      cpu    = 0.75
      memory = "1.5Gi"

      env {
        name  = "KAFKA_CFG_NODE_ID"
        value = "0"
      }
      env {
        name  = "KAFKA_CFG_PROCESS_ROLES"
        value = "controller,broker"
      }
      env {
        name  = "KAFKA_CFG_CONTROLLER_QUORUM_VOTERS"
        value = "0@127.0.0.1:9093"
      }
      env {
        name  = "KAFKA_CFG_LISTENERS"
        value = "PLAINTEXT://:9092,CONTROLLER://:9093"
      }
      env {
        name  = "KAFKA_CFG_ADVERTISED_LISTENERS"
        value = "PLAINTEXT://${var.prefix}-kafka:9092"
      }
      env {
        name  = "KAFKA_CFG_CONTROLLER_LISTENER_NAMES"
        value = "CONTROLLER"
      }
      env {
        name  = "KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP"
        value = "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
      }
      env {
        name  = "KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE"
        value = "true"
      }
      env {
        name  = "ALLOW_PLAINTEXT_LISTENER"
        value = "yes"
      }
    }
  }
}

# ── Redis de RESPALDO (interno) ───────────────────────────────────────────────
# El primario es Upstash; este contenedor recibe la doble escritura del cliente
# resiliente (REDIS_FALLBACK_URL) → si Upstash cae, el juego sigue sin perder
# las partidas en curso. volatile-lru: solo expulsa claves con TTL (las salas).
resource "azurerm_container_app" "redis" {
  name                         = "${var.prefix}-redis"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  ingress {
    external_enabled = false
    target_port      = 6379
    exposed_port     = 6379
    transport        = "tcp"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "redis"
      image  = "redis:7-alpine"
      cpu    = 0.25
      memory = "0.5Gi"
      args   = ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "volatile-lru"]
    }
  }
}
