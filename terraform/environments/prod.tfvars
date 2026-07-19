# Valores NO secretos del ambiente PROD — este archivo SÍ se versiona en git.
# Secrets vía TF_VAR_* desde el GitHub Environment "production" (o terraform.tfvars local).

environment      = "prod"
prefix           = "battlecaosprod"
gateway_replicas = 3      # los "3 gateways" reales, balanceados por Container Apps
image_tag        = "prod" # tag INMUTABLE — nunca ":latest" en producción
deploy_frontend  = false
