locals {
  # Baseline applied to every zone; var.zone_settings overrides per domain.
  zone_settings = merge(
    {
      ssl                      = "strict"
      always_use_https         = "on"
      min_tls_version          = "1.2"
      tls_1_3                  = "on"
      automatic_https_rewrites = "on"
    },
    var.zone_settings
  )

  mail_records = var.proton == null ? {} : merge(
    {
      verification = { name = var.domain, type = "TXT", content = "protonmail-verification=${var.proton.verification}" }
      spf          = { name = var.domain, type = "TXT", content = "v=spf1 include:_spf.protonmail.ch ~all" }
      mx_default   = { name = var.domain, type = "MX", content = "mail.protonmail.ch", priority = 10 }
      mx_sec       = { name = var.domain, type = "MX", content = "mailsec.protonmail.ch", priority = 20 }
      dmarc        = { name = "_dmarc.${var.domain}", type = "TXT", content = var.proton.dmarc }
    },
    { for i, prefix in ["protonmail", "protonmail2", "protonmail3"] :
      "dkim_${i + 1}" => {
        name    = "${prefix}._domainkey.${var.domain}"
        type    = "CNAME"
        content = "${prefix}.domainkey.${var.proton.dkim_target}.domains.proton.ch"
      }
    }
  )

  caa_records = merge([
    for issuer in var.caa_issuers : {
      for tag in ["issue", "issuewild"] : "${tag}_${issuer}" => { tag = tag, issuer = issuer }
    }
  ]...)
}
