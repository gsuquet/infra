---
status: proposed
date: 2026-11-19
decision-makers: repository owner
---

# Use OpenTofu as the IaC tool

## Context and Problem Statement

`infra` provisions kind, Talos and GKE clusters, bootstraps Gateway API CRDs, Cilium and Argo CD, and manages
landing zones (`landing-zone/cloudflare` today). It uses Terraform 1.17.2 with an R2 S3 backend. The Talos
provider can keep machine secrets and kubeconfigs out of state with ephemeral resources and write-only inputs;
without that pattern they land in state, which has only server-side encryption at rest in R2 and no object
versioning. Which IaC tool should the repository use before the cluster roots are written?

Full study: [IaC tool research](../research/iac-tool.md).

## Decision Drivers

- Keep long-lived secrets out of state (ephemeral resources, write-only arguments), and keep what remains
  unreadable to anyone holding only the state bucket or its token.
- Support ephemeral resources and write-only arguments (Talos provider 0.12.0: `talos_machine`, `talos_cluster`,
  `talos_machine_configuration_apply`).
- Open-source license with no ambiguity for a public repository used individually and non-commercially.
- Use the providers the plan needs: talos, kind, helm, kubernetes, google, cloudflare 5.x.
- Keep the existing R2 backend with native lock files, `pass-cli run`, mise pins, pre-commit hooks and Renovate.
- Low migration cost; plans that a reviewer or an agent reads easily.

## Considered Options

- Terraform (stay on 1.17)
- OpenTofu 1.13
- Pulumi (Go or TypeScript, DIY R2 backend or Pulumi Cloud)

## Decision Outcome

Chosen option: "OpenTofu 1.13", because it has the ephemeral resources and write-only arguments the Talos
provider needs, it is MPL-2.0, it keeps HCL, the providers and the R2 backend, and it adds client-side state and
plan encryption as defense in depth. Encryption stops a leaked R2 token, Cloudflare-side access and stray plan
files; it does **not** stop agents, which run as the owner's OS user, unless the key is out of their reach
(see the [threat model](../research/iac-tool.md#threat-model-state-secrets) and ADR 0020 question 10). The
primary control for Talos remains the ephemeral / write-only pattern.

The switch happens only after a read-only `tofu plan` on `landing-zone/cloudflare` shows no changes.

Encryption configuration lives in code: an `encryption` block with the `pbkdf2` key provider, a sensitive
passphrase variable fed by `pass-cli run`, and `enforced = true` on `state` and `plan`. `TF_ENCRYPTION` is not
used, so the check below can read the configuration from the code. One passphrase per environment. Revisit the
key provider when the secrets study and `landing-zone/gcp` conclude (`gcp_kms` with an identity agents do not
hold, or `openbao`).

### Consequences

- Good, because whatever secret still reaches state or a saved plan is encrypted before it reaches R2.
- Good, because the license question is closed for good.
- Good, because the migration is done while only `landing-zone/cloudflare` exists.
- Bad, because losing a passphrase loses the state, and R2 cannot roll it back.
- Bad, because Terraform-only features will not be available.
- Bad, because the switch is more than a binary rename: `required_version` is replaced by a top-level
  `language { compatible_with { opentofu = "..." } }` block (OpenTofu ignores `required_version`); both
  `.terraform.lock.hcl` files are rewritten to `registry.opentofu.org` addresses with `h1:` hashes; the
  `terraform_providers_lock` hook must run tofu or be dropped; `tfupdate` no longer manages the pin; Renovate
  needs `registryUrls` for registry.opentofu.org and a regex manager (or a range) for the `compatible_with` pin.
  All of these change in one PR, or lock files flip between registries.
- Neutral, because tflint 0.66.0 and trivy 0.76.1 accept the `encryption` and `language` blocks (tested).

### Confirmation

- A read-only `tofu plan` on `landing-zone/cloudflare` shows no changes before the first encrypted apply.
- Every R2-backed root declares an `encryption` block with `enforced = true` on `state` and `plan`; a check
  (Conftest on HCL or a script in pre-commit) fails an R2-backed root without it. kind roots are excluded until
  open question 2 of the research is answered.
- An R2 state object downloaded with the state token contains no known secret string and no plaintext
  `resources` attribute values.

## Pros and Cons of the Options

### Terraform

- Good, because it is the reference: provider docs, tflint, trivy and Renovate target it first.
- Good, because it has ephemeral resources and write-only arguments (1.11+).
- Bad, because it has no client-side state encryption: secrets without a write-only variant stay readable to
  anyone with the R2 token.
- Bad, because the BSL license adds a question for a public repository, even if non-commercial use is allowed (unverified).

### OpenTofu

- Good, because of state and plan encryption with `pbkdf2`, KMS, OpenBao or external key providers.
- Good, because of ephemeral resources and write-only arguments (1.11+), `use_lockfile` on S3 (1.10+).
- Good, because every provider of the plan is in registry.opentofu.org.
- Good, because of MPL-2.0 under the Linux Foundation.
- Neutral, because HCL and the backend configuration stay; the lock files are rewritten once.
- Bad, because Terraform-only features will not arrive, and the version pin and lock files need tooling changes.

### Pulumi

- Good, because Go and TypeScript are first-class, with unit tests in the same language.
- Good, because secret values are encrypted per value in state with a passphrase or KMS provider.
- Bad, because `_wo` values from bridged providers are still stored in state (encrypted as secrets), and changes
  to them are not diffed.
- Bad, because Talos comes from a community package (`pulumiverse` v0.8.1, 2026-07-29) that predates upstream
  0.12.0 and has no `talos_machine` / `talos_cluster`; kind needs a generated local SDK.
- Bad, because the DIY backend is not transactional, and Pulumi Cloud adds a SaaS dependency that holds state.
- Bad, because the landing zone, hooks and Renovate rules need a rewrite.
- Bad, because the rendered manifests pattern keeps the IaC layer small, so a general-purpose language adds little.

## More Information

- Relates to ADRs 0015 (bootstrap boundary), 0017 (repository layout), 0018 (Terraform state backends) and 0019
  (lifecycle tasks and CI scope) in [PR #5](https://github.com/gsuquet/infra/pull/5), and ADR 0020 (secrets
  backend, open question 10) in [PR #4](https://github.com/gsuquet/infra/pull/4). Those ADRs say "Terraform" for
  the language family (HCL, state, providers); the wording stays until this ADR is accepted, then the switch PR
  updates them.
- Files the switch PR changes: `.mise/config.toml` and `mise.lock`, `.mise/tasks/tf` and the `cluster:*` tasks,
  `.pre-commit-config.yaml` (`terraform_providers_lock`, `tfupdate`), `.github/renovate.json` ("terraform cli" and
  "terraform providers" groups, lock file maintenance), `landing-zone/cloudflare/terraform.tf` and both
  `.terraform.lock.hcl` files.
- [OpenTofu state encryption](https://opentofu.org/docs/language/state/encryption/)
- [OpenTofu settings: `language` block](https://opentofu.org/docs/language/settings/)
- [Talos provider: using ephemeral resources](https://registry.terraform.io/v2/provider-docs/13749226)
- [Terraform write-only arguments](https://developer.hashicorp.com/terraform/language/resources/ephemeral/write-only)
- [Pulumi write-only fields](https://www.pulumi.com/docs/iac/concepts/secrets/write-only-fields/)
- Open questions are listed in the [research](../research/iac-tool.md#open-questions).
- Revisit if OpenTofu stops tracking provider protocol changes, or if Terraform adds client-side state encryption.
