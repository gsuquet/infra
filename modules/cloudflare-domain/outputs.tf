output "zone_id" {
  description = "ID of the Cloudflare zone"
  value       = cloudflare_zone.this.id
}

output "zone_name_servers" {
  description = "Cloudflare nameservers to set at the domain's registrar"
  value       = cloudflare_zone.this.name_servers
}

output "zone_dnssec_ds" {
  description = "DS record of the zone, to publish at the registrar when it is not Cloudflare"
  value       = cloudflare_zone_dnssec.this.ds
}

output "dns_record_ids" {
  description = "IDs of the managed DNS records, keyed by record key"
  value = merge(
    { for k, r in cloudflare_dns_record.mail : k => r.id },
    { for k, r in cloudflare_dns_record.caa : "caa_${k}" => r.id },
  )
}
