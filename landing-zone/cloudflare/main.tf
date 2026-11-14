resource "cloudflare_r2_bucket" "state" {
  account_id = var.account_id
  name       = var.state_bucket_name
  location   = var.state_bucket_location

  # Holds this configuration's own state.
  lifecycle {
    prevent_destroy = true
  }
}

module "domain" {
  source   = "./modules/domain"
  for_each = var.domains

  account_id    = var.account_id
  domain        = each.key
  zone_settings = each.value.zone_settings
  caa_issuers   = each.value.caa_issuers
  proton        = each.value.proton
}
