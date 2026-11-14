resource "cloudflare_zone" "this" {
  account = { id = var.account_id }
  name    = var.domain
  type    = "full"

  # Destroying a zone wipes every record and setting in it.
  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zone_setting" "this" {
  for_each = local.zone_settings

  zone_id    = cloudflare_zone.this.id
  setting_id = each.key
  value      = each.value
}

resource "cloudflare_zone_dnssec" "this" {
  zone_id = cloudflare_zone.this.id
  status  = "active"

  # Disabling DNSSEC while a DS record is published at the registry makes the zone unresolvable.
  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "mail" {
  for_each = local.mail_records

  zone_id = cloudflare_zone.this.id
  name    = each.value.name
  type    = each.value.type
  # The API stores TXT content quoted (see the imported SPF record); unquoted content would diff on every plan.
  content  = each.value.type == "TXT" ? "\"${each.value.content}\"" : each.value.content
  priority = try(each.value.priority, null)
  ttl      = 1
}

# Cloudflare adds hidden CAA records for its own Universal SSL CAs once any CAA record exists.
resource "cloudflare_dns_record" "caa" {
  for_each = local.caa_records

  zone_id = cloudflare_zone.this.id
  name    = var.domain
  type    = "CAA"
  ttl     = 1
  data = {
    flags = 0
    tag   = each.value.tag
    value = each.value.issuer
  }
}

# HSTS: browsers refuse plain HTTP for max_age seconds, on every subdomain too. Not preloaded: preload is near-irreversible.
resource "cloudflare_zone_setting" "security_header" {
  zone_id    = cloudflare_zone.this.id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = var.hsts_max_age
      include_subdomains = true
      preload            = false
      nosniff            = true
    }
  }
}
