---
status: proposed
date: 2026-11-18
decision-makers: repository owner
---

# Use OpenTofu as the IaC tool

## Context and Problem Statement

`infra` provisions kind, Talos and GKE clusters, bootstraps Gateway API CRDs, Cilium and Argo CD, and manages
landing zones (`landing-zone/cloudflare` today). It uses Terraform 1.17.2 with an R2 S3 backend. Talos
machine secrets and cluster kubeconfigs would end up in Terraform state, which today has only server-side
encryption at rest in R2 and no object versioning. Which IaC tool should the repository use before the
cluster roots are written?

Full study: [IaC tool research](../research/iac-tool.md).

## Decision Drivers

- Keep secrets (Talos machine secrets, kubeconfigs, Helm values) unreadable in the state bucket.
- Support ephemeral resources and write-only arguments (Talos provider 0.12.0 uses both).
- Open-source license with no ambiguity for a public personal repository.
- Use the providers the plan needs: talos, kind, helm, kubernetes, google, cloudflare 5.x.
- Keep the existing R2 backend with native lock files, `pass-cli run`, mise pins, pre-commit hooks and Renovate.
- Low migration cost; plans that a reviewer or an agent reads easily.

## Considered Options

- Terraform (stay on 1.17)
- OpenTofu 1.13
- Pulumi (Go or TypeScript, DIY R2 backend or Pulumi Cloud)

## Decision Outcome

Chosen option: "OpenTofu 1.13", because it is the only option that encrypts the whole state and plan files
on the client, it has the ephemeral resources and write-only arguments the Talos provider needs, it is
MPL-2.0, and it keeps HCL, the providers and the R2 backend, so the migration of the one existing root is small.

Start with the `pbkdf2` key provider (passphrase in Proton Pass, passed through `TF_ENCRYPTION` by
`pass-cli run`) and `enforced = true`. Revisit the key provider when the secrets study and `landing-zone/gcp`
conclude (`gcp_kms` or `openbao`).

### Consequences

- Good, because every secret that reaches state or a saved plan is encrypted before it reaches R2.
- Good, because the license question is closed for good.
- Good, because the migration is done while only `landing-zone/cloudflare` exists.
- Bad, because losing the passphrase loses the state, and R2 cannot roll it back.
- Bad, because OpenTofu lags Terraform features, and future Terraform-only features will not be available.
- Bad, because tflint, trivy and tfupdate are Terraform-first: OpenTofu-only syntax may need exclusions (unverified).
- Neutral, because Renovate needs a `registryUrls` rule for registry.opentofu.org and a new rule for the CLI version.

### Confirmation

- `tofu init` and `tofu plan` on `landing-zone/cloudflare` show no changes before the first encrypted apply.
- Every root declares an `encryption` block with `enforced = true`; a check (tflint rule, Conftest on HCL or a
  script in pre-commit) fails a root without it.
- An R2 state object downloaded with the state token is not readable JSON.

## Pros and Cons of the Options

### Terraform

- Good, because it is the reference: provider docs, tflint, trivy and Renovate target it first.
- Good, because it has ephemeral resources and write-only arguments (1.11+).
- Bad, because it has no client-side state encryption: secrets without a write-only variant stay readable in R2.
- Bad, because the BSL license adds a question for a public repository, even if personal use is allowed (unverified).

### OpenTofu

- Good, because of state and plan encryption with `pbkdf2`, KMS, OpenBao or external key providers.
- Good, because of ephemeral resources and write-only arguments (1.11+), `use_lockfile` on S3 (1.10+).
- Good, because every provider of the plan is in registry.opentofu.org.
- Good, because of MPL-2.0 under the Linux Foundation.
- Neutral, because HCL, `.terraform.lock.hcl` and the backend configuration stay the same.
- Bad, because of feature lag and Terraform-first linters.

### Pulumi

- Good, because Go and TypeScript are first-class, with unit tests in the same language.
- Good, because secret values are encrypted per value in state with a passphrase or KMS provider.
- Bad, because Talos comes from a community bridge (`pulumiverse`) and kind needs a generated local SDK.
- Bad, because the DIY backend is not transactional, and Pulumi Cloud adds a SaaS dependency that holds state.
- Bad, because the landing zone, hooks and Renovate rules need a rewrite.
- Bad, because the rendered manifests pattern keeps the IaC layer small, so a general-purpose language adds little.

## More Information

- [OpenTofu state encryption](https://opentofu.org/docs/language/state/encryption/)
- [Talos provider: using ephemeral resources](https://registry.terraform.io/v2/provider-docs/13749226)
- [Terraform write-only arguments](https://developer.hashicorp.com/terraform/language/resources/ephemeral/write-only)
- [Pulumi secrets](https://www.pulumi.com/docs/iac/concepts/secrets/)
- Open questions are listed in the [research](../research/iac-tool.md#open-questions).
- Revisit if OpenTofu stops tracking provider protocol changes, or if Terraform adds client-side state encryption.
