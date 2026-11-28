resource "cloudflare_account" "this" {
  name = var.account_name

  settings = {
    enforce_twofactor = true
  }

  lifecycle {
    prevent_destroy = true
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

resource "cloudflare_r2_bucket" "state" {
  account_id = var.account_id
  name       = var.state_bucket_name
  location   = var.state_bucket_location

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_organization" "this" {
  account_id                  = var.account_id
  name                        = var.zero_trust_team_name
  auth_domain                 = "${var.zero_trust_team_name}.cloudflareaccess.com"
  session_duration            = "24h"
  auto_redirect_to_identity   = false
  allow_authenticate_via_warp = true
  warp_auth_session_duration  = "24h"
}

resource "cloudflare_zero_trust_access_identity_provider" "cloudflare" {
  account_id = var.account_id
  name       = "Cloudflare"
  type       = "cloudflare"

  config = {
    restrict_to_account_members = true
  }
}

resource "cloudflare_zero_trust_access_identity_provider" "onetimepin" {
  account_id = var.account_id
  name       = "One-time PIN"
  type       = "onetimepin"
  config     = {}
}

resource "cloudflare_zero_trust_access_identity_provider" "passkeys" {
  account_id = var.account_id
  name       = "Passkeys"
  type       = "passkeys"

  config = {
    login_page_auto_prompt = false
  }
}

resource "cloudflare_zero_trust_access_group" "member" {
  for_each = local.access_group_members

  account_id = var.account_id
  name       = each.key
  include    = [for email in each.value : { email = { email = email } }]
}

resource "cloudflare_zero_trust_access_group" "strong_login" {
  account_id = var.account_id
  name       = "strong-login"
  include    = [for id in local.strong_login_identity_provider_ids : { login_method = { id = id } }]
}

resource "cloudflare_zero_trust_access_policy" "this" {
  for_each = local.access_policies

  account_id       = var.account_id
  name             = each.key
  decision         = "allow"
  session_duration = local.access_tiers[each.value.tier].session_duration

  include = [for g in each.value.groups : { group = { id = cloudflare_zero_trust_access_group.member[g].id } }]

  require = local.access_tiers[each.value.tier].strong_login && var.access_strong_login_enforced ? [
    { group = { id = cloudflare_zero_trust_access_group.strong_login.id } }
  ] : null
}

resource "cloudflare_zero_trust_access_application" "catch_all" {
  for_each = var.domains

  account_id           = var.account_id
  type                 = "self_hosted"
  name                 = "catch-all ${each.key}"
  domain               = "*.${each.key}"
  destinations         = [{ type = "public", uri = "*.${each.key}" }]
  session_duration     = "24h"
  app_launcher_visible = false
  policies             = [{ id = cloudflare_zero_trust_access_policy.this["household-standard"].id, precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "app_launcher" {
  account_id          = var.account_id
  type                = "app_launcher"
  landing_page_design = { title = "Welcome!" }
  name                = "App Launcher"
  session_duration    = "24h"
  policies            = [{ id = cloudflare_zero_trust_access_policy.this["household-standard"].id, precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "warp" {
  account_id       = var.account_id
  type             = "warp"
  name             = "Warp Login App"
  session_duration = "24h"
  policies         = [{ id = cloudflare_zero_trust_access_policy.this["household-standard"].id, precedence = 1 }]
}

module "domain" {
  source   = "../../modules/cloudflare-domain"
  for_each = var.domains

  account_id    = var.account_id
  domain        = each.key
  zone_settings = each.value.zone_settings
  caa_issuers   = each.value.caa_issuers
  proton        = each.value.proton
  hsts_max_age  = each.value.hsts_max_age
}
