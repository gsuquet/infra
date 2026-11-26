# OpenTofu ignores terraform.required_version: the language block pins the CLI.
# Keep it equal to opentofu in .mise/config.toml (Renovate moves both together).
language {
  compatible_with {
    opentofu = "1.13.9"
  }
}

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.28.1"
    }
  }
}
