# Tooling and migration detail for RFC 0022

<!-- readability: allow-code R2 -->

This page holds the reasons, the local tests and the files behind the switch.
The decision is in [RFC 0022](../rfc/0022-iac-tool.md#decision).

**(unverified)** marks a claim from prior knowledge that no allowed documentation domain or local test confirmed.

## Reasons for the settled choices

| Topic | Reason and detail beyond the [Decision](../rfc/0022-iac-tool.md#decision) |
|---|---|
| Version pin | OpenTofu ignores `required_version` (`"99.0.0"` passes `tofu init` and `tofu validate` on 1.13.9, local test); `compatible_with` is enforced; the exact pin moves with the mise pin through a Renovate regex manager |
| `terraform_providers_lock` | Run as is, it rewrites lock files back to `registry.terraform.io`; if the hook is dropped, regenerate lock files with `tofu providers lock` |
| `tfupdate` | It only rewrites `required_version`, which OpenTofu ignores; Renovate already updates providers |
| Encryption check | Gives the Confirmation an owner |
| Key provider | Config in code is checkable; the secrets backend ([RFC 0020](https://github.com/gsuquet/infra/pull/4)) and `landing-zone/gcp` do not exist yet |
| Passphrases | One per environment: production roots, everything else; an offline copy kept apart from Pass, checked by decrypting a downloaded state once; docs advise one key per state for KMS and OpenBao providers only; each extra passphrase is one more item to lose |
| kind roots | Local, disposable state; `cluster:up` on kind must work offline and without secrets ([ADR 0018](../adr/0018-terraform-state-backends.md)) |
| File extension | tflint and trivy are tested on `encryption` and `language` blocks in `.tf`; `.tofu` is not |
| Gate | Read-only `tofu init` + `tofu plan` against the R2 state written by Terraform 1.17.2 shows no changes before merge; not run in the study: needs the R2 read token |

## Local tests

Local tests on a scratch copy of `landing-zone/cloudflare` without credentials, repo pins (tflint 0.66.0, trivy
0.76.1, tfupdate 0.10.3), OpenTofu 1.13.9, `encryption` block (`pbkdf2`, `enforced = true`) and `language` block in
`.tf`:

| Check | Result |
|---|---|
| `tofu init -backend=false`, `tofu validate` | Pass |
| tflint | No error on either block |
| `trivy config --exit-code 1` | 0 misconfigurations |
| `tfupdate opentofu -v` | Rewrites `required_version` only |

## Impact per tool

| Tool | Change |
|---|---|
| pre-commit-terraform | The `--tf-path` / `PCT_TFPATH` override to tofu is **(unverified)** |
| tflint | `terraform_required_version` rule disabled (OpenTofu ignores `required_version`); otherwise unchanged (tested) |
| trivy | Unchanged (tested) |
| terraform-docs | Works on HCL **(unverified)** |
| Renovate | `terraform` manager reads `*.tf` and `*.tofu`; `registryUrls: ["https://registry.opentofu.org"]` in a `packageRule` ([manager](https://docs.renovatebot.com/modules/manager/terraform/)); the `language` block is not managed **(unverified: not documented)**; lock file maintenance is done by Renovate itself, whether it writes `registry.opentofu.org` addresses is **(unverified)** |
| mise, CI | `terraform` replaced by `opentofu`; CI takes tools from mise |
| `pass-cli run` | Unchanged; the passphrase variable comes from Pass like the R2 token |
| Plan output | Plan text stays the most common IaC diff format; `tofu plan -json-into=plan.json` gives text and JSON in one run; an encrypted saved plan needs the key to be read by a tool |

## Files of the switch PR

Every switch PR change lands together, or lock files flip between registries.

| File | Change |
|---|---|
| `.mise/config.toml`, `.mise/mise.lock` | `terraform` replaced by `opentofu`; `tfupdate` removed |
| `.mise/tasks/tf`, `cluster:*` tasks | Call `tofu` |
| `.pre-commit-config.yaml` | `--tf-path=tofu` on `terraform_fmt`, `terraform_providers_lock` and `terraform_validate`, `tfupdate` dropped, tflint `--config` arg, encryption check added |
| `.tflint.hcl` | `terraform_required_version` rule disabled |
| `.github/renovate.json` | "terraform cli" group renamed "opentofu cli", matching `opentofu` / `opentofu/opentofu`; a regex manager for the `language` block pin (`github-releases`, `opentofu/opentofu`); a `packageRule` sets `registryUrls` to registry.opentofu.org for `terraform-module` and `terraform-provider`; one lock file maintenance run checked |
| `landing-zone/cloudflare/terraform.tf`, `modules/cloudflare-domain/terraform.tf` | `required_version` replaced by the `language` block |
| Both `.terraform.lock.hcl` | Regenerated with `tofu init` / `tofu providers lock`; diff reviewed (address, header, `h1:` hashes) |
