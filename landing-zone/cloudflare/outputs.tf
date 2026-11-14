output "zone_name_servers" {
  description = "Cloudflare nameservers to set at each domain's registrar, keyed by domain"
  value       = { for d, m in module.domain : d => m.zone_name_servers }
}

output "state_r2_bucket_name" {
  description = "Name of the R2 bucket storing Terraform states"
  value       = cloudflare_r2_bucket.state.name
}

output "zero_trust_organization_auth_domain" {
  description = "Zero Trust team domain"
  value       = cloudflare_zero_trust_organization.this.auth_domain
}

output "zero_trust_access_policy_ids" {
  description = "IDs of the reusable Access policies, keyed by name, referenced by tenant Access applications"
  value       = { for name, p in cloudflare_zero_trust_access_policy.this : name => p.id }
}
