# ============================================================================
#  Kafka CLÚSTER de 3 brokers (OPT-IN) — var.kafka_brokers = 3
#
#  Elimina el SPOF del bus de eventos: 3 brokers KRaft con replication.factor=3 y
#  min.insync.replicas=2 → tolera la caída de 1 broker sin perder mensajes ni disponibilidad.
#
#  Cada broker es un Container App SEPARADO (kafka-0/1/2) — así tiene DNS interno ESTABLE
#  (battlecaos-kafka-N), lo que un solo Container App con N réplicas NO da (Kafka es stateful).
#  Cada uno monta su propio Azure File share para /var/lib/kafka/data (persistencia).
#
#  ⚠️ Migrar de 1→3 es DESTRUCTIVO: recrea el bus y hay que subir el RF de los topics ya
#     existentes (kafka-reassign-partitions). Triplica CPU/mem. Ver deploy/HA-RONDA-B-APPLY.md.
# ============================================================================

locals {
  kafka_ids = var.kafka_brokers == 3 ? toset(["0", "1", "2"]) : toset([])

  # Lista de votantes del quórum de controladores: "0@kafka-0:9093,1@kafka-1:9093,2@kafka-2:9093".
  kafka_quorum_voters = join(",", [
    for id in ["0", "1", "2"] : "${id}@${var.prefix}-kafka-${id}:9093"
  ])

  # Bootstrap servers que usan los SERVICIOS (KAFKA_BROKER). 1 broker → el actual; 3 → los tres.
  kafka_bootstrap = var.kafka_brokers == 3 ? join(",", [
    for id in ["0", "1", "2"] : "${var.prefix}-kafka-${id}:9092"
  ]) : "${var.prefix}-kafka:9092"
}

# ── Almacenamiento persistente por broker (Azure Files) ───────────────────────
resource "azurerm_storage_account" "kafka" {
  count                    = var.kafka_brokers == 3 ? 1 : 0
  name                     = "${var.prefix}kafka${substr(md5(azurerm_resource_group.rg.id), 0, 6)}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_share" "kafka" {
  for_each           = local.kafka_ids
  name               = "kafka-${each.key}"
  storage_account_id = azurerm_storage_account.kafka[0].id
  quota              = 10 # GiB
}

# Registrar cada share en el Environment para poder montarlo en los container apps.
resource "azurerm_container_app_environment_storage" "kafka" {
  for_each                     = local.kafka_ids
  name                         = "kafka-${each.key}"
  container_app_environment_id = azurerm_container_app_environment.env.id
  account_name                 = azurerm_storage_account.kafka[0].name
  share_name                   = azurerm_storage_share.kafka[each.key].name
  access_key                   = azurerm_storage_account.kafka[0].primary_access_key
  access_mode                  = "ReadWrite"
}

# ── Los 3 brokers ─────────────────────────────────────────────────────────────
resource "azurerm_container_app" "kafka_broker" {
  for_each                     = local.kafka_ids
  name                         = "${var.prefix}-kafka-${each.key}"
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
    max_replicas = 1 # cada broker es UNA réplica con identidad estable

    volume {
      name         = "data"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.kafka[each.key].name
    }

    container {
      name   = "kafka"
      image  = "apache/kafka:3.7.0"
      cpu    = 0.75
      memory = "1.5Gi"

      volume_mounts {
        name = "data"
        path = "/var/lib/kafka/data"
      }

      env {
        name  = "KAFKA_NODE_ID"
        value = each.key
      }
      env {
        name  = "KAFKA_PROCESS_ROLES"
        value = "controller,broker"
      }
      env {
        name  = "KAFKA_CONTROLLER_QUORUM_VOTERS"
        value = local.kafka_quorum_voters
      }
      env {
        name  = "KAFKA_LISTENERS"
        value = "PLAINTEXT://:9092,CONTROLLER://:9093"
      }
      env {
        name  = "KAFKA_ADVERTISED_LISTENERS"
        value = "PLAINTEXT://${var.prefix}-kafka-${each.key}:9092"
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
        name  = "KAFKA_LOG_DIRS"
        value = "/var/lib/kafka/data"
      }
      env {
        name  = "KAFKA_AUTO_CREATE_TOPICS_ENABLE"
        value = "true"
      }
      env {
        name  = "KAFKA_NUM_PARTITIONS"
        value = "6"
      }
      # RF=3 y min ISR=2 → tolera 1 broker caído sin perder datos.
      env {
        name  = "KAFKA_DEFAULT_REPLICATION_FACTOR"
        value = "3"
      }
      env {
        name  = "KAFKA_MIN_INSYNC_REPLICAS"
        value = "2"
      }
      env {
        name  = "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR"
        value = "3"
      }
      env {
        name  = "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR"
        value = "3"
      }
      env {
        name  = "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR"
        value = "2"
      }
    }
  }
}
