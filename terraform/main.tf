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

  # Redundancia de ZONA (OPT-IN, DESTRUCTIVO): el provider exige `zone_redundancy_enabled` e
  # `infrastructure_subnet_id` juntos o ninguno → NO se puede gate con variable aquí sin romper
  # el plan por defecto. Para activarla, DESCOMENTA las 2 líneas de abajo (y pon
  # enable_zone_redundancy=true para crear la VNet/subred de zone-redundancy.tf). Recrea el env
  # y TODAS las apps → solo en ventana de mantenimiento. Ver deploy/HA-RONDA-B-APPLY.md.
  # infrastructure_subnet_id = azurerm_subnet.aca[0].id
  # zone_redundancy_enabled  = true
}

# ── Kafka (interno) ───────────────────────────────────────────────────────────
# Un broker KRaft (sin zookeeper) dentro del Environment. Los servicios lo alcanzan
# como battlecaos-kafka:9092. Nota: almacenamiento efímero — si el contenedor se
# reinicia se pierden mensajes en vuelo; aceptable porque los topics transportan
# comandos/eventos transitorios (el ESTADO vive en Redis/Atlas).
# Broker ÚNICO (kafka_brokers=1, default). Con kafka_brokers=3 se apaga (count=0) y lo
# reemplaza el clúster de kafka-cluster.tf. El `moved` evita recrear el broker actual al
# introducir el count (renombra kafka → kafka[0] en el estado sin destruir/crear).
moved {
  from = azurerm_container_app.kafka
  to   = azurerm_container_app.kafka[0]
}

resource "azurerm_container_app" "kafka" {
  count                        = var.kafka_brokers == 1 ? 1 : 0
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
      name = "kafka"
      # apache/kafka = imagen OFICIAL del proyecto (la de bitnami fue retirada
      # de Docker Hub por Broadcom en 2025 → MANIFEST_UNKNOWN al desplegar).
      # Mismo modo KRaft; las vars cambian de prefijo KAFKA_CFG_* → KAFKA_*.
      image  = "apache/kafka:3.7.0"
      cpu    = 0.75
      memory = "1.5Gi"

      env {
        name  = "KAFKA_NODE_ID"
        value = "0"
      }
      env {
        name  = "KAFKA_PROCESS_ROLES"
        value = "controller,broker"
      }
      env {
        name  = "KAFKA_CONTROLLER_QUORUM_VOTERS"
        value = "0@127.0.0.1:9093"
      }
      env {
        name  = "KAFKA_LISTENERS"
        value = "PLAINTEXT://:9092,CONTROLLER://:9093"
      }
      env {
        name  = "KAFKA_ADVERTISED_LISTENERS"
        value = "PLAINTEXT://${var.prefix}-kafka:9092"
      }
      env {
        name  = "KAFKA_CONTROLLER_LISTENER_NAMES"
        value = "CONTROLLER"
      }
      env {
        name  = "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP"
        value = "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
      }
      env {
        name  = "KAFKA_AUTO_CREATE_TOPICS_ENABLE"
        value = "true"
      }
      # Particiones por defecto para los topics auto-creados: 6 → permite repartir el
      # trabajo entre varias réplicas de los servicios de dominio (autoescalado KEDA).
      # Como todo va keyed por `codigo`, cada sala queda confinada a UNA partición y se
      # procesa en orden; distintas salas se distribuyen entre réplicas.
      env {
        name  = "KAFKA_NUM_PARTITIONS"
        value = "6"
      }
      # Broker único: los topics internos no pueden pedir réplicas > 1.
      env {
        name  = "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR"
        value = "1"
      }
      env {
        name  = "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR"
        value = "1"
      }
      env {
        name  = "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR"
        value = "1"
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
