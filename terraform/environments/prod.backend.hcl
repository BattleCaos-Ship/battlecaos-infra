# Config del backend remoto para el ambiente PROD. Usar con:
#   terraform init -backend-config=environments/prod.backend.hcl -reconfigure
resource_group_name = "battlecaos-tfstate-rg"
storage_account_name = "sttfstate67f1e1ad"
container_name        = "tfstate"
key                    = "prod.terraform.tfstate"
