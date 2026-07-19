# Config del backend remoto para el ambiente DEV. Usar con:
#   terraform init -backend-config=environments/dev.backend.hcl -reconfigure
resource_group_name = "battlecaos-tfstate-rg"
storage_account_name = "sttfstate67f1e1ad"
container_name        = "tfstate"
key                    = "dev.terraform.tfstate"
