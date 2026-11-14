variable "account_id" {
  description = "Cloudflare account identifier owning the zone"
  type        = string
  sensitive   = true
  nullable    = false
}

variable "domain" {
  description = "Apex domain name of the zone"
  type        = string
  nullable    = false
}

variable "zone_settings" {
  description = "Zone settings overriding the baseline, keyed by setting ID (e.g. ssl = \"full\")"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "caa_issuers" {
  description = "Certificate authorities allowed to issue for the zone, besides Cloudflare's own CAs; empty disables CAA records"
  type        = list(string)
  default     = ["letsencrypt.org"]
  nullable    = false
}

variable "proton" {
  description = "Proton Mail settings for this domain; null disables mail records"
  type = object({
    verification = string # value after "protonmail-verification="
    dkim_target  = string # per-domain hash in the DKIM CNAME targets
    dmarc        = string
  })
  default = null
}
