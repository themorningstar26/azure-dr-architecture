terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.90" }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstatemyapp001"
    container_name       = "tfstate-primary"
    key                  = "primary.terraform.tfstate"
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
  env    = "primary"
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
  node_count          = var.node_count
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
  is_primary          = true
}

resource "azurerm_mssql_failover_group" "main" {
  name      = "fog-${local.prefix}"
  server_id = module.sql.server_id
  databases = [module.sql.database_id]
  partner_server { id = var.dr_sql_server_id }
  read_write_endpoint_failover_policy {
    mode          = "Automatic"
    grace_minutes = 1
  }
}

module "frontdoor" {
  source              = "../../modules/frontdoor"
  name                = "afd-${local.prefix}-global"
  resource_group_name = azurerm_resource_group.main.name
  primary_host        = var.primary_aks_ingress_ip
  dr_host             = var.dr_aks_ingress_ip
  health_probe_path   = "/health"
}

module "automation" {
  source                 = "../../modules/automation"
  resource_group_name    = azurerm_resource_group.main.name
  location               = var.location
  dr_resource_group      = "rg-${local.prefix}-dr"
  primary_resource_group = azurerm_resource_group.main.name
  subscription_id        = var.arm_subscription_id
}

module "monitoring" {
  source                = "../../modules/monitoring"
  resource_group_name   = azurerm_resource_group.main.name
  frontdoor_profile_id  = module.frontdoor.profile_id
  automation_account_id = module.automation.automation_account_id
  runbook_name          = module.automation.runbook_name
  webhook_uri           = module.automation.webhook_uri
  oncall_email          = var.oncall_email
  slack_webhook_url     = var.slack_webhook_url
}
