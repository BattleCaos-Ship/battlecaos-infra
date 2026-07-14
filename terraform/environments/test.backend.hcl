# Config del backend remoto para el ambiente TEST. Usar con:
#   terraform init -backend-config=environments/test.backend.hcl -reconfigure
resource_group_name = "battlecaos-tfstate-rg"
storage_account_name = "sttfstate67f1e1ad"
container_name        = "tfstate"
key                    = "test.terraform.tfstate"
