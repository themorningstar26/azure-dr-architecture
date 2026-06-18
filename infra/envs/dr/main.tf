terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.90" }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstatemyapp001"
    container_name       = "tfstate-dr"
    key                  = "dr.terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
  client_id       = var.arm_client_id
  client_secret   = var.arm_client_secret
  tenant_id       = var.arm_tenant_id
  subscription_id = var.arm_subscription_id
}

locals {
  env    = "dr"
  prefix = "myapp"
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.prefix}-${local.env}"
  location = var.location
}

module "aks" {
  source              = "../../modules/aks"
  cluster_name        = "aks-${local.prefix}-${local.env}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  node_count          = var.node_count      # 2 — warm standby
  node_sku            = var.node_sku
  acr_id              = var.acr_id
  key_vault_id        = var.key_vault_id
  arm_tenant_id       = var.arm_tenant_id
}

module "sql" {
  source              = "../../modules/sql"
  server_name         = "sql-${local.prefix}-${local.env}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  admin_password      = var.db_admin_password
  is_primary          = false                      # creates as replica
  primary_server_id   = var.primary_sql_server_id
}

output "dr_aks_ingress_ip"  { value = module.aks.cluster_name }
output "dr_sql_server_id"   { value = module.sql.server_id }
