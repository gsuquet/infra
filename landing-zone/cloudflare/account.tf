# The account exists before Terraform (sign-up): imported, never created or destroyed here.
# Members and roles stay in the dashboard: the only member is the owner (Super Administrator).
resource "cloudflare_account" "this" {
  name = var.account_name
  settings = {
    enforce_twofactor = true # every member must use 2FA
  }

  lifecycle {
    prevent_destroy = true
  }
}
