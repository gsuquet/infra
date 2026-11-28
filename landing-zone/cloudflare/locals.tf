locals {
  access_tiers = {
    standard  = { session_duration = "24h", strong_login = false }
    sensitive = { session_duration = "8h", strong_login = true }
  }

  access_policies = {
    "owner-sensitive"    = { tier = "sensitive", groups = ["owner"] }
    "household-standard" = { tier = "standard", groups = ["owner", "household"] }
    "family-sensitive"   = { tier = "sensitive", groups = ["owner", "family"] }
  }

  access_group_members = {
    for name, g in var.access_groups : name => distinct(concat(
      g.emails,
      flatten([for included in g.includes : var.access_groups[included].emails])
    ))
    if length(g.emails) + length(g.includes) > 0
  }

  notification_policies = {
    "abuse-report"  = { alert_type = "abuse_report_alert", description = "Cloudflare receives an abuse report about the account" }
    "tunnel-health" = { alert_type = "tunnel_health_event", description = "A Cloudflare Tunnel turns healthy, degraded or down" }
    "tunnel-update" = { alert_type = "tunnel_update_event", description = "A Cloudflare Tunnel is created or deleted" }
    "universal-ssl" = { alert_type = "universal_ssl_event_type", description = "A Universal SSL certificate is validated, issued, renewed or expires" }
  }

  strong_login_identity_provider_ids = compact([
    cloudflare_zero_trust_access_identity_provider.passkeys.id,
    var.github_identity_provider_id,
  ])
}
