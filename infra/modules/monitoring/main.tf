variable "resource_group_name" {}
variable "frontdoor_profile_id" {}
variable "automation_account_id" {}
variable "runbook_name" {}
variable "webhook_uri" { sensitive = true }
variable "oncall_email" { default = "oncall@yourcompany.com" }
variable "slack_webhook_url" { sensitive = true }

resource "azurerm_monitor_action_group" "dr_trigger" {
  name                = "ag-dr-failover-trigger"
  resource_group_name = var.resource_group_name
  short_name          = "drfailover"
  automation_runbook_receiver {
    name                    = "scale-dr-runbook"
    automation_account_id   = var.automation_account_id
    runbook_name            = var.runbook_name
    webhook_resource_id     = "${var.automation_account_id}/webhooks/webhook-dr-failover"
    is_global_runbook       = false
    service_uri             = var.webhook_uri
    use_common_alert_schema = true
  }
  email_receiver {
    name          = "oncall-email"
    email_address = var.oncall_email
    use_common_alert_schema = true
  }
  webhook_receiver {
    name        = "slack-notify"
    service_uri = var.slack_webhook_url
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "primary_down" {
  name                = "alert-primary-region-down"
  resource_group_name = var.resource_group_name
  scopes              = [var.frontdoor_profile_id]
  severity            = 0
  frequency           = "PT1M"
  window_size         = "PT5M"
  criteria {
    metric_namespace = "Microsoft.Cdn/profiles"
    metric_name      = "OriginHealthPercentage"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 100
    dimension {
      name     = "OriginGroup"
      operator = "Include"
      values   = ["app-origin-group"]
    }
  }
  action { action_group_id = azurerm_monitor_action_group.dr_trigger.id }
}
