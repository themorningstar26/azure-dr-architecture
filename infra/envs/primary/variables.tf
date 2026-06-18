variable "location" {}
variable "node_count" { default = 5 }
variable "node_sku" { default = "Standard_D4s_v3" }
variable "acr_id" {}
variable "key_vault_id" {}
variable "arm_client_id" {}
variable "arm_client_secret" { sensitive = true }
variable "arm_tenant_id" {}
variable "arm_subscription_id" {}
variable "db_admin_password" { sensitive = true }
variable "dr_sql_server_id" { default = "" }
variable "dr_aks_ingress_ip" { default = "" }
variable "primary_aks_ingress_ip" { default = "" }
variable "oncall_email" {}
variable "slack_webhook_url" { sensitive = true; default = "" }
