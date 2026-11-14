variable "account_id" {
  description = "Cloudflare account identifier (set via TF_VAR_account_id)"
  type        = string
  sensitive   = true
  nullable    = false
}

variable "domains" {
  description = "Domains managed in this account, keyed by apex domain name"
  type = map(object({
    zone_settings = optional(map(string), {})
    caa_issuers   = optional(list(string), ["letsencrypt.org"])
    proton = optional(object({
      verification = string
      dkim_target  = string
      dmarc        = optional(string, "v=DMARC1; p=quarantine")
    }))
  }))
  default = {
    "gsuquet.com" = {
      proton = {
        verification = "454bd6dc87d5f8902d743764672696a158aff8cf"
        dkim_target  = "dreoysz2xi4pom4tvksmruysugk2khqrsns6in2gqsgq357nzl3ea"
      }
    }
  }
}

variable "zero_trust_team_name" {
  description = "Zero Trust team name, chosen at onboarding; the team domain is <name>.cloudflareaccess.com"
  type        = string
  default     = "gsuquet"
}

variable "access_groups" {
  description = "Access groups keyed by name: member emails, and groups whose members they include (one level). Set in the gitignored private.auto.tfvars"
  type = map(object({
    emails   = optional(list(string), [])
    includes = optional(list(string), [])
  }))
  nullable = false

  validation {
    condition = alltrue([
      for g in ["owner", "household", "family"] : length(try(var.access_groups[g].emails, [])) + length(try(var.access_groups[g].includes, [])) > 0
    ])
    error_message = "Groups owner, household and family are used by the reusable policies and need members."
  }

  validation {
    condition     = alltrue(flatten([for g in values(var.access_groups) : [for i in g.includes : contains(keys(var.access_groups), i)]]))
    error_message = "Every included group must be a key of access_groups."
  }
}

variable "github_identity_provider_id" {
  description = "ID of the GitHub identity provider created in the dashboard, accepted as a strong login; null until it exists"
  type        = string
  default     = null
}

variable "access_strong_login_enforced" {
  description = "Require a passkey or GitHub login on sensitive policies; enable once every member has enrolled a passkey"
  type        = bool
  default     = true
  nullable    = false
}

variable "state_bucket_name" {
  description = "Name of the R2 bucket storing Terraform states; must match the bucket in backend.tf"
  type        = string
  default     = "terraform-state"
  nullable    = false
}

variable "state_bucket_location" {
  description = "Location hint of the state bucket, only honored at creation"
  type        = string
  default     = "weur"
  nullable    = false

  validation {
    condition     = contains(["apac", "eeur", "enam", "weur", "wnam", "oc"], var.state_bucket_location)
    error_message = "Must be one of apac, eeur, enam, weur, wnam, oc."
  }
}
