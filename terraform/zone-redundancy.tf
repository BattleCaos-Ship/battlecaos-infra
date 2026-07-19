# ============================================================================
#  Redundancia de ZONA (OPT-IN) — var.enable_zone_redundancy = true
#
#  La redundancia de zona reparte las réplicas entre varias Availability Zones → si una
#  zona (AZ) cae, las réplicas de las otras siguen sirviendo. Es una propiedad INMUTABLE
#  del Container Apps Environment (activarla RECREA el env y todas sus apps) y REQUIERE una
#  subred de infraestructura delegada a Microsoft.App/environments.
#
#  Estos recursos solo se crean si el flag está activo (count=0 por defecto → sin cambios).
#  East US 2 (la región del proyecto) soporta AZs.
# ============================================================================

resource "azurerm_virtual_network" "aca" {
  count               = var.enable_zone_redundancy ? 1 : 0
  name                = "${var.prefix}-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.20.0.0/16"]
}

# Subred de infraestructura del Environment. Container Apps (Consumption) exige un bloque
# mínimo /23 y la delegación a Microsoft.App/environments.
resource "azurerm_subnet" "aca" {
  count                = var.enable_zone_redundancy ? 1 : 0
  name                 = "${var.prefix}-aca-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.aca[0].name
  address_prefixes     = ["10.20.0.0/23"]

  delegation {
    name = "aca-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}
