# Cloudflare landing zone

Composition managing the foundation of the Cloudflare account:

- the R2 bucket holding Terraform states;
- one `domain` module instance ([`modules/cloudflare-domain`](../../modules/cloudflare-domain)) per entry in `terraform.tfvars`: zone, baseline settings, DNSSEC, CAA, Proton Mail records;
- the Zero Trust foundation: organization, identity providers without a secret (one-time PIN, passkeys, Cloudflare account), Access groups, reusable policies (`<audience>-<tier>`), and the account-wide applications (catch-all per domain, WARP login, App Launcher).

Application Workers, R2 buckets and Access applications belong to the tenant layer.
No secret value is created by a resource of this configuration: such values would be stored in state.

## Manual prerequisites

1. **Zero Trust onboarding**, in the dashboard: choose the team name and the Free plan. Payment details are required even on Free. Set `zero_trust_team_name` in `terraform.tfvars`.
2. **OAuth identity providers** (GitHub, Google, LinkedIn), in the dashboard (Zero Trust → Settings → Authentication). Not managed here: their `client_secret` is not write-only in provider 5.28.1, so Terraform would store it in state. Each needs an OAuth app at the provider with the redirect URL `https://<team>.cloudflareaccess.com/cdn-cgi/access/callback`; LinkedIn also needs the "Sign In with LinkedIn using OpenID Connect" product. Every provider can sign the owner in: add only the ones you use.
3. **Access group members and notification recipients**, in the gitignored `local.auto.tfvars`: `access_groups = { owner = { emails = [...] }, household = {...}, family = { emails = [...], includes = ["household"] } }` and `notification_emails = ["..."]`.
4. **IDs of existing resources**, in `imports.tf`: `mise run cf:ids <domain>` and `mise run cf:zt-ids`.
5. **Budget alert**, in the dashboard (Billing → Billable Usage → Create budget alert): one email when the usage-based spend of the billing period crosses a dollar threshold, e.g. R2 beyond its free tier. Not managed here: provider 5.29.0 and earlier lack the `billing_budget_alert` type.

## Usage

Credentials live in Proton Pass. `pass/*.env` hold only `pass://<vault>/<item>/<field>` references, which
`pass-cli run` resolves into the environment of the OpenTofu process alone, masking them in its output.

| Pass item (vault `Personal`) | Fields |
|---|---|
| `cloudflare-infra-write` | `password`: account API token (write), `account_id` |
| `cloudflare-infra-read` | `password`: read-only twin, `account_id` |
| `cloudflare-infra-r2-state` | `username`: R2 token ID, `password`: SHA-256 of the token value, `endpoint`: `https://<account_id>.r2.cloudflarestorage.com` |

```sh
pass-cli login
mise run tf init
mise run tf:read plan -lock=false     # read-only token, for review and agents
mise run tf apply
pass-cli run --env-file pass/read.env -- mise run cf:ids gsuquet.com
```

## Bootstrap (first apply only)

This configuration creates the R2 bucket that stores its own state, so the first apply runs on local state,
before the `cloudflare-infra-r2-state` item exists (hence `pass-cli run` without `pass/state.env`):

```sh
printf 'terraform {\n  backend "local" {}\n}\n' > bootstrap_override.tf   # gitignored
pass-cli run --env-file pass/write.env -- tofu init
pass-cli run --env-file pass/write.env -- tofu apply   # creates the state bucket, imports existing resources
rm bootstrap_override.tf
# Create an R2 API token scoped to the bucket in the dashboard, store it as cloudflare-infra-r2-state
mise run tf init -migrate-state       # copies local state into R2
rm terraform.tfstate terraform.tfstate.backup
```

The bucket has `prevent_destroy`, and R2 refuses to delete a non-empty bucket.
R2 has no object versioning: a corrupted state cannot be rolled back from the bucket.

To add a domain, add it to `domains` in `terraform.tfvars`, apply, then set the `zone_name_servers` output at the registrar.
To adopt a zone created manually, list its IDs with `mise run cf:ids <domain>` and add them to `imports.tf` before applying.
