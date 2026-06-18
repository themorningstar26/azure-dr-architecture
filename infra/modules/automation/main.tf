variable "resource_group_name" {}
variable "location" {}
variable "dr_resource_group" {}
variable "primary_resource_group" {}
variable "subscription_id" {}

resource "azurerm_automation_account" "dr" {
  name                = "aa-myapp-dr-failover"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "Basic"
  identity { type = "SystemAssigned" }
}

resource "azurerm_role_assignment" "runbook_dr_contributor" {
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.dr_resource_group}"
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.dr.identity[0].principal_id
}

resource "azurerm_role_assignment" "runbook_primary_reader" {
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.primary_resource_group}"
  role_definition_name = "Reader"
  principal_id         = azurerm_automation_account.dr.identity[0].principal_id
}

resource "azurerm_automation_runbook" "dr_scale" {
  name                    = "runbook-dr-failover-scale"
  resource_group_name     = var.resource_group_name
  location                = var.location
  automation_account_name = azurerm_automation_account.dr.name
  log_verbose             = true
  log_progress            = true
  runbook_type            = "PowerShell"
  content                 = file("${path.module}/../../../../runbook/dr-failover.ps1")
}

resource "azurerm_automation_webhook" "dr" {
  name                    = "webhook-dr-failover"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.dr.name
  runbook_name            = azurerm_automation_runbook.dr_scale.name
  expiry_time             = "2030-01-01T00:00:00Z"
  enabled                 = true
}

output "automation_account_id" { value = azurerm_automation_account.dr.id }
output "runbook_name"          { value = azurerm_automation_runbook.dr_scale.name }
output "webhook_uri"           { value = azurerm_automation_webhook.dr.uri; sensitive = true }
output "msi_principal_id"      { value = azurerm_automation_account.dr.identity[0].principal_id }
