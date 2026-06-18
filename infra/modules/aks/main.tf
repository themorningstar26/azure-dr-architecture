variable "cluster_name" {}
variable "resource_group_name" {}
variable "location" {}
variable "node_count" { default = 2 }
variable "node_sku" { default = "Standard_D2s_v3" }
variable "acr_id" {}
variable "key_vault_id" {}
variable "arm_tenant_id" {}

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = "1.28"
  default_node_pool {
    name                = "system"
    node_count          = var.node_count
    vm_size             = var.node_sku
    os_disk_size_gb     = 128
    enable_auto_scaling = true
    min_count           = var.node_count
    max_count           = 10
  }
  identity { type = "SystemAssigned" }
  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
  }
}

resource "azurerm_role_assignment" "aks_acr" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

resource "azurerm_key_vault_access_policy" "aks" {
  key_vault_id       = var.key_vault_id
  tenant_id          = var.arm_tenant_id
  object_id          = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  secret_permissions = ["Get", "List"]
}

output "cluster_id"          { value = azurerm_kubernetes_cluster.main.id }
output "cluster_name"        { value = azurerm_kubernetes_cluster.main.name }
output "kube_config"         { value = azurerm_kubernetes_cluster.main.kube_config_raw; sensitive = true }
output "kubelet_identity_id" { value = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id }
