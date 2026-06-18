variable "name" {}
variable "resource_group_name" {}
variable "primary_host" {}
variable "dr_host" {}
variable "health_probe_path" { default = "/health" }

resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = var.name
  resource_group_name = var.resource_group_name
  sku_name            = "Standard_AzureFrontDoor"
}

resource "azurerm_cdn_frontdoor_origin_group" "main" {
  name                     = "app-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  health_probe {
    path                = var.health_probe_path
    protocol            = "Https"
    interval_in_seconds = 30
    request_type        = "GET"
  }
  load_balancing {
    sample_size                 = 4
    successful_samples_required = 2
  }
}

resource "azurerm_cdn_frontdoor_origin" "primary" {
  name                           = "primary-east-us"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.main.id
  enabled                        = true
  host_name                      = var.primary_host
  origin_host_header             = var.primary_host
  priority                       = 1
  weight                         = 1000
  http_port                      = 80
  https_port                     = 443
  certificate_name_check_enabled = true
}

resource "azurerm_cdn_frontdoor_origin" "dr" {
  name                           = "dr-west-europe"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.main.id
  enabled                        = true
  host_name                      = var.dr_host
  origin_host_header             = var.dr_host
  priority                       = 2
  weight                         = 1000
  http_port                      = 80
  https_port                     = 443
  certificate_name_check_enabled = true
}

resource "azurerm_cdn_frontdoor_endpoint" "main" {
  name                     = "app-endpoint"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
}

resource "azurerm_cdn_frontdoor_route" "main" {
  name                          = "app-route"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.primary.id, azurerm_cdn_frontdoor_origin.dr.id]
  supported_protocols           = ["Http", "Https"]
  patterns_to_match             = ["/*"]
  forwarding_protocol           = "HttpsOnly"
  https_redirect_enabled        = true
}

output "frontend_endpoint" { value = azurerm_cdn_frontdoor_endpoint.main.host_name }
output "profile_id"        { value = azurerm_cdn_frontdoor_profile.main.id }
