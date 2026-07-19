# Valores NO secretos del ambiente DEV — este archivo SÍ se versiona en git.
# Los secrets (redis_url, mongo_url, jwt_secret, google_client_id) NO van aquí:
# en CI llegan como variables TF_VAR_* desde los secrets del GitHub Environment
# "dev"; en local, desde tu terraform.tfvars (gitignoreado).

environment      = "dev"
prefix           = "battlecaosdev"
gateway_replicas = 2     # activo/activo REAL en reposo: si una réplica cae, la otra sigue
                         # sirviendo sin gap (antes min=1: la probe recreaba, pero con un
                         # hueco de segundos). Decidido 2026-07-18 al cerrar disponibilidad.
image_tag        = "dev" # las imágenes de dev se etiquetan :dev (última construida)
deploy_frontend  = true  # el frontend YA está desplegado → true evita que `terraform apply` lo destruya
                         # (con false, terraform lo daba de baja: trampa que mordía en cada apply)
