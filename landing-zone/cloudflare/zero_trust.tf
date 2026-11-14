# Zero Trust foundation: organization, identity providers, groups (who), reusable policies (who + how strictly),
# and the account-wide applications. Applications of an app belong to the tenant layer, next to the app.

# Created at dashboard onboarding (plan selection and payment details are required, even on Free), then imported.
resource "cloudflare_zero_trust_organization" "this" {
  account_id                = var.account_id
  name                      = var.zero_trust_team_name
  auth_domain               = "${var.zero_trust_team_name}.cloudflareaccess.com"
  session_duration          = "24h"
  auto_redirect_to_identity = false # several identity providers: let the login page offer them all
  # Kept as found at import: a device enrolled in WARP signs users in to Access applications.
  allow_authenticate_via_warp = true
  warp_auth_session_duration  = "24h"
}

# --- Identity providers ---
# Providers without a secret are managed here.
# OAuth providers (GitHub, Google, LinkedIn) are created in the dashboard: config.client_secret is not
# write-only in provider 5.28.1, so it would be stored in state. GitHub is referenced by var.github_identity_provider_id.

resource "cloudflare_zero_trust_access_identity_provider" "onetimepin" {
  account_id = var.account_id
  name       = "One-time PIN"
  type       = "onetimepin"
  config     = {}
}

# Enrollment first verifies the user with another login method.
resource "cloudflare_zero_trust_access_identity_provider" "passkeys" {
  account_id = var.account_id
  name       = "Passkeys"
  type       = "passkeys"
  config = {
    login_page_auto_prompt = false
  }
}

resource "cloudflare_zero_trust_access_identity_provider" "cloudflare" {
  account_id = var.account_id
  name       = "Cloudflare"
  type       = "cloudflare"
  config = {
    restrict_to_account_members = true # otherwise any Cloudflare user can authenticate
  }
}

# --- Groups ---

resource "cloudflare_zero_trust_access_group" "member" {
  for_each = local.access_group_members

  account_id = var.account_id
  name       = each.key
  include    = [for email in each.value : { email = { email = email } }]
}

# include is OR: a passkey or a GitHub login. Policies require this group, since values of one require rule are ANDed.
resource "cloudflare_zero_trust_access_group" "strong_login" {
  account_id = var.account_id
  name       = "strong-login"
  include    = [for id in local.strong_login_identity_provider_ids : { login_method = { id = id } }]
}

# --- Reusable policies ---

resource "cloudflare_zero_trust_access_policy" "this" {
  for_each = local.access_policies

  account_id       = var.account_id
  name             = each.key
  decision         = "allow"
  session_duration = local.access_tiers[each.value.tier].session_duration

  include = [for g in each.value.groups : { group = { id = cloudflare_zero_trust_access_group.member[g].id } }]

  # TODO: access_strong_login_enforced defaults to false so members can enroll a passkey first; enable it once done.
  require = local.access_tiers[each.value.tier].strong_login && var.access_strong_login_enforced ? [
    { group = { id = cloudflare_zero_trust_access_group.strong_login.id } }
  ] : null
}

# --- Account-wide applications ---

# Deny by default: every subdomain without a more specific Access application needs a household login.
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

# Who may enroll a device in WARP.
resource "cloudflare_zero_trust_access_application" "warp" {
  account_id       = var.account_id
  type             = "warp"
  name             = "Warp Login App"
  session_duration = "24h"
  policies         = [{ id = cloudflare_zero_trust_access_policy.this["household-standard"].id, precedence = 1 }]
}

# The launcher lists only the applications each user may open.
resource "cloudflare_zero_trust_access_application" "app_launcher" {
  account_id          = var.account_id
  type                = "app_launcher"
  landing_page_design = { title = "Welcome!" } # the default title, explicit: omitted or {}, it diffs on every plan
  name                = "App Launcher"
  session_duration    = "24h"
  policies            = [{ id = cloudflare_zero_trust_access_policy.this["household-standard"].id, precedence = 1 }]
}
