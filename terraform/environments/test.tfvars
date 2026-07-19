# Valores NO secretos del ambiente TEST — este archivo SÍ se versiona en git.
# Secrets vía TF_VAR_* desde el GitHub Environment "test" (o terraform.tfvars local).

environment      = "test"
prefix           = "battlecaostest"
gateway_replicas = 2      # un poco más de paralelismo para probar el balanceo
image_tag        = "test" # imágenes promovidas de dev tras pasar sus pruebas
deploy_frontend  = false
