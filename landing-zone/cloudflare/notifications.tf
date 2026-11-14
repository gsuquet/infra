# Account notifications, sent by email. Alert types are limited to those available on the Free plan.
# TODO: add the budget alert (alert_type billing_budget_alert, filter total_spend_dollars) once the provider supports it;
# until then it is created in the dashboard (README, manual prerequisites).
locals {
  notification_policies = {
    "tunnel-health" = { alert_type = "tunnel_health_event", description = "A Cloudflare Tunnel turns healthy, degraded or down" }
    "tunnel-update" = { alert_type = "tunnel_update_event", description = "A Cloudflare Tunnel is created or deleted" }
    "universal-ssl" = { alert_type = "universal_ssl_event_type", description = "A Universal SSL certificate is validated, issued, renewed or expires" }
    "abuse-report"  = { alert_type = "abuse_report_alert", description = "Cloudflare receives an abuse report about the account" }
  }
}

resource "cloudflare_notification_policy" "this" {
  for_each = local.notification_policies

  account_id  = var.account_id
  name        = each.key
  description = each.value.description
  alert_type  = each.value.alert_type
  enabled     = true
  mechanisms = {
    email = [for email in var.notification_emails : { id = email }]
  }
}
