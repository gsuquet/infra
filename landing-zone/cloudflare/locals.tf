locals {
  # How strictly a policy authenticates.
  access_tiers = {
    standard  = { session_duration = "24h", strong_login = false }
    sensitive = { session_duration = "8h", strong_login = true }
  }

  # Reusable policies, named <audience>-<tier>; tenant Access applications reference them by ID.
  access_policies = {
    "owner-sensitive"    = { tier = "sensitive", groups = ["owner"] }
    "household-standard" = { tier = "standard", groups = ["owner", "household"] }
    "family-sensitive"   = { tier = "sensitive", groups = ["owner", "family"] }
  }

  # Group members, with included groups expanded one level (an Access group referencing another group
  # of the same for_each resource would be a dependency cycle). Empty groups are not created.
  access_group_members = {
    for name, g in var.access_groups : name => distinct(concat(
      g.emails,
      flatten([for included in g.includes : var.access_groups[included].emails])
    ))
    if length(g.emails) + length(g.includes) > 0
  }

  # Login methods accepted as strong: passkeys, and GitHub once created in the dashboard.
  strong_login_identity_provider_ids = compact([
    cloudflare_zero_trust_access_identity_provider.passkeys.id,
    var.github_identity_provider_id,
  ])
}
