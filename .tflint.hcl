plugin "terraform" {
  enabled = true
  preset  = "all"
}

# OpenTofu ignores terraform.required_version: the top-level language block
# (compatible_with.opentofu) pins the CLI instead, and tofu enforces it.
rule "terraform_required_version" {
  enabled = false
}
