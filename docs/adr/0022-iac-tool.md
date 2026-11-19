---
adr: 0022
title: Use OpenTofu as the IaC tool
status: accepted
date: 2026-11-19
rfc: docs/rfc/0022-iac-tool.md
review: https://github.com/gsuquet/infra/pull/11
---

# 0022. Use OpenTofu as the IaC tool

- Status: accepted on 2026-11-19 by gsuquet
- Decision: In the context of the IaC layer of `infra` (landing zones, bootstrap modules, cluster roots for kind, Talos and GKE), facing Talos secrets that need ephemeral resources and write-only inputs and R2 state with only server-side encryption, we decided for OpenTofu 1.13 with client-side state and plan encryption and against staying on Terraform 1.17 and against Pulumi, to achieve an unambiguous open-source license, the Talos ephemeral pattern and encrypted R2 state and plans, accepting a tooling migration and the loss of Terraform-only features.
- Rules:
  - Switch in one PR: mise `opentofu`, tasks call `tofu`, `required_version` replaced by top-level `language { compatible_with { opentofu = "~> 1.13.9" } }` (or exact pin plus Renovate regex manager), both `.terraform.lock.hcl` regenerated for `registry.opentofu.org`, `terraform_providers_lock` runs tofu or is dropped, `tfupdate` dropped or limited to providers, Renovate `registryUrls` for registry.opentofu.org.
  - Merge the switch only after a read-only `tofu plan` on `landing-zone/cloudflare` shows no changes.
  - Every R2-backed root: `encryption` block in code, `pbkdf2` key provider, sensitive passphrase variable from `pass-cli run`, `enforced = true` on `state` and `plan`; no `TF_ENCRYPTION`. Migrate with an `unencrypted` fallback, apply once, then remove it.
  - One passphrase per environment (production, rest), with an offline backup.
  - kind roots: local state, not encrypted.
  - `.tf` files only, no `.tofu`.
  - Talos roots use ephemeral resources and write-only inputs; encryption is defense in depth, not the primary control.
  - ADRs 0015, 0017, 0018, 0019 say "Terraform" for the language family; the switch PR updates their wording.
- Consequences:
  - Good: a secret still reaching state or a saved plan is encrypted before R2; a leaked R2 token, Cloudflare-side access or a stray plan file reads nothing.
  - Good: the license question is closed.
  - Good: the migration happens while only `landing-zone/cloudflare` exists.
  - Bad: a lost passphrase loses the state; R2 cannot roll it back.
  - Bad: encryption does not stop agents or anyone holding the owner's Pass session.
  - Bad: Terraform-only features will not be available; tooling (pin, lock files, hooks, Renovate) changes once.
- Confidence: medium, a moderate preference: with the full Talos ephemeral pattern R2 states hold almost no long-lived secret, and pre-commit-terraform, Renovate and terraform-docs behavior with tofu is unverified.
- Confirmation: read-only `tofu plan` with no changes before the first encrypted apply; a pre-commit check (Conftest on HCL or a script) fails an R2-backed root without `enforced = true` on `state` and `plan`; a downloaded R2 state object holds no known secret string and no plaintext `resources` values.
- Revisit when: OpenTofu stops tracking provider protocol changes, Terraform adds client-side state encryption, or the secrets backend and `landing-zone/gcp` exist (move the key provider to `gcp_kms` or `openbao` with an identity agents do not hold).

Source: [RFC 0022](../../docs/rfc/0022-iac-tool.md), reviewed in https://github.com/gsuquet/infra/pull/11.
