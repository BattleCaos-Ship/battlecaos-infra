# Valores NO secretos del ambiente DEV — este archivo SÍ se versiona en git.
# Los secrets (redis_url, mongo_url, jwt_secret, google_client_id) NO van aquí:
# en CI llegan como variables TF_VAR_* desde los secrets del GitHub Environment
# "dev"; en local, desde tu terraform.tfvars (gitignoreado).

environment      = "dev"
prefix           = "battlecaosdev"
gateway_replicas = 1     # dev no necesita alta disponibilidad — 1 réplica basta
image_tag        = "dev" # las imágenes de dev se etiquetan :dev (última construida)
deploy_frontend  = false # activar en la 2ª pasada, cuando la imagen del frontend ya exista
