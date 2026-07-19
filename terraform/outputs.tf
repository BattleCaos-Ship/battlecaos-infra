output "acr_login_server" {
  description = "Servidor del registro — úsalo en 'az acr build'"
  value       = azurerm_container_registry.acr.login_server
}

output "acr_name" {
  description = "Nombre del ACR"
  value       = azurerm_container_registry.acr.name
}

output "gateway_url" {
  description = "URL pública del gateway (VITE_GATEWAY_URL del frontend)"
  value       = "https://${azurerm_container_app.gateway.ingress[0].fqdn}"
}

output "auth_url" {
  description = "URL pública del auth (VITE_AUTH_URL del frontend)"
  value       = "https://${azurerm_container_app.auth.ingress[0].fqdn}"
}

output "frontend_url" {
  description = "URL pública del juego (agregarla a los orígenes autorizados de Google OAuth)"
  value       = var.deploy_frontend ? "https://${azurerm_container_app.frontend[0].ingress[0].fqdn}" : "(pendiente — segunda pasada con deploy_frontend=true)"
}
