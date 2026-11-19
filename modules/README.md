# Modules

Every Terraform child module (`cluster-*`, `bootstrap-*`, `cloudflare-domain`): no backend, no provider configuration, called by the roots in `landing-zone/` and `clusters/`.
Each module, its purpose and status: [Terraform roots and modules](../docs/reference/terraform-modules.md#modules).
