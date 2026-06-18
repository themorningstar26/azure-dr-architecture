variable "server_name" {}
variable "resource_group_name" {}
variable "location" {}
variable "admin_password" { sensitive = true }
variable "is_primary" { default = true }
variable "primary_server_id" { default = "" }
variable "db_name" { default = "appdb" }

resource "azurerm_mssql_server" "main" {
  name                         = var.server_name
  resource_group_name          = var.resource_group_name
  location                     = var.location
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = var.admin_password
  minimum_tls_version          = "1.2"
}

resource "azurerm_mssql_database" "main" {
  count              = var.is_primary ? 1 : 0
  name               = var.db_name
  server_id          = azurerm_mssql_server.main.id
  sku_name           = "S2"
  max_size_gb        = 50
  geo_backup_enabled = true
}

resource "azurerm_mssql_database" "replica" {
  count                               = var.is_primary ? 0 : 1
  name                                = var.db_name
  server_id                           = azurerm_mssql_server.main.id
  create_mode                         = "Secondary"
  creation_source_database_id         = "${var.primary_server_id}/databases/${var.db_name}"
  sku_name                            = "S2"
}

output "server_id"   { value = azurerm_mssql_server.main.id }
output "server_name" { value = azurerm_mssql_server.main.name }
output "server_fqdn" { value = azurerm_mssql_server.main.fully_qualified_domain_name }
output "database_id" { value = var.is_primary ? azurerm_mssql_database.main[0].id : azurerm_mssql_database.replica[0].id }
