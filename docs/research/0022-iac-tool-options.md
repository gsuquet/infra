# IaC tool options compared for RFC 0022

<!-- readability: allow-code R2 -->

This page compares Terraform 1.17, OpenTofu 1.13 and Pulumi, criterion by criterion.
The decision is in [RFC 0022](../rfc/0022-iac-tool.md#decision).

Researched on 2026-11-18, updated on 2026-11-19. **(unverified)** marks a claim from prior knowledge that no allowed documentation domain or local test confirmed;
every other claim links to its source or names the local test.

## Comparison

| Criterion | Terraform 1.17 | OpenTofu 1.13 | Pulumi (Go / TypeScript) |
|---|---|---|---|
| License | BSL 1.1 since 1.6 **(unverified)**; use in a public repository used individually and non-commercially is allowed, the restriction targets competing hosted products **(unverified)**; providers stay MPL-2.0 **(unverified)** | MPL-2.0 ([LICENSE](https://github.com/opentofu/opentofu/blob/main/LICENSE)), Linux Foundation project ([FAQ](https://opentofu.org/faq/)) | Apache-2.0 for CLI and SDKs ([LICENSE](https://github.com/pulumi/pulumi/blob/master/LICENSE)); Pulumi Cloud is a proprietary SaaS |
| Latest version | 1.17.x ([upgrade guide](https://developer.hashicorp.com/terraform/language/upgrade-guides)) | 1.13.9, 2026-11-05 ([releases](https://github.com/opentofu/opentofu/releases)) | CLI 3.276.0 (`mise ls-remote pulumi`) |
| Ephemeral resources | Yes ([ephemeral block](https://developer.hashicorp.com/terraform/language/block/ephemeral)); 1.10+ per the Talos guide | Yes, 1.11+ ([1.11](https://opentofu.org/docs/v1.11/intro/whats-new/)) | No equivalent found; secret outputs encrypted in state instead |
| Write-only arguments | 1.11+, never in state or plan ([write-only](https://developer.hashicorp.com/terraform/language/resources/ephemeral/write-only)) | 1.11+, never in state or plan ([ephemerality](https://opentofu.org/docs/language/ephemerality/)) | Supported but **kept in state**: the initial value "gets written to Pulumi state inputs as a Secret" and changes are not diffed ([write-only fields](https://www.pulumi.com/docs/iac/concepts/secrets/write-only-fields/)) |
| Version pin in code | `terraform { required_version }` | Top-level `language { compatible_with { opentofu = "..." } }`, 1.12+ ([settings](https://opentofu.org/docs/language/settings/)); `"99.0.0"`, `"1.13.8"` and `"1.13.10"` fail with "Incompatible module" on 1.13.9 (local test); `required_version` is **not** enforced (`tofu validate` passes with `"99.0.0"`, local test, 1.13.9) | `requiredVersion` in `Pulumi.yaml` **(unverified)** |
| S3/R2 backend, native lock | `use_lockfile`, opt-in; DynamoDB locking deprecated ([S3](https://developer.hashicorp.com/terraform/language/settings/backends/s3)) | `use_lockfile` since 1.10, same `skip_*` and `use_path_style` options ([S3](https://opentofu.org/docs/language/settings/backends/s3/), [1.10](https://opentofu.org/docs/v1.10/intro/whats-new/)); `init -backend=false` + `validate` pass on the current root (local test); real backend init not run | DIY backend with `endpoint=` and `s3ForcePathStyle=`, file lock under `locks/` ([DIY](https://www.pulumi.com/docs/iac/operations/stack-management/using-a-diy-backend/)); not transactional, "cannot transparently recover from certain kinds of partial failures" ([state](https://www.pulumi.com/docs/iac/concepts/state-and-backends/)) |
| Client-side state encryption | None; backend encryption at rest only **(unverified: no such feature in the docs read)** | Since 1.7: state **and** plan, local and remote, AES-GCM; key providers `pbkdf2`, `aws_kms`, `gcp_kms`, `azure_vault`, `openbao`, `external`; `fallback` for migration, `enforced = true`; config in code and/or `TF_ENCRYPTION`, environment wins on conflict ([encryption](https://opentofu.org/docs/language/state/encryption/)) | Per value: secrets encrypted with the stack provider (`passphrase`, `awskms`, `gcpkms`, `azurekeyvault`, `hashivault`, Pulumi Cloud) ([secrets](https://www.pulumi.com/docs/iac/concepts/secrets/)); rest of state in plain text; passphrase from `PULUMI_CONFIG_PASSPHRASE[_FILE]` ([env](https://www.pulumi.com/docs/iac/cli/environment-variables/)) |
| Lock file | `.terraform.lock.hcl`, `registry.terraform.io/...` addresses | Same file, but `tofu init` **rewrites** it: new header, address `registry.opentofu.org/cloudflare/cloudflare`, 8 `h1:` hashes added, `zh:` kept, same binary (local test) | `go.sum` / `package-lock.json` for SDKs; plugin versions not locked **(unverified)** |
| Provider registry | talos 0.12.0 (partner, 2026-09-21), kind 0.13.0 (community) | talos, kind, helm, kubernetes, google, cloudflare all on registry.opentofu.org ([opentofu/registry](https://github.com/opentofu/registry), `gh api`); same binaries | Native kubernetes, gcp; cloudflare bridged v6.24.0 = upstream 5.29.0, days of lag ([releases](https://github.com/pulumi/pulumi-cloudflare/releases)); Talos community `pulumiverse` v0.8.1 (2026-07-29, [API docs](https://www.pulumi.com/registry/packages/talos/api-docs/)), before upstream 0.12.0 ([versions](https://registry.terraform.io/v2/providers/siderolabs/talos/provider-versions)), `machine` module has only `Bootstrap`, `ConfigurationApply`, `Secrets` ([machine](https://www.pulumi.com/registry/packages/talos/api-docs/machine/)); kind: no package, generate a local SDK with `pulumi package add terraform-provider tehcyx/kind` ([any provider](https://www.pulumi.com/docs/iac/concepts/providers/any-terraform-provider/)) |
| Provider-defined functions | Yes **(unverified version)** | Since 1.7 ([functions](https://opentofu.org/docs/language/functions/)) | Not applicable: host language |
| Testing | `terraform test` 1.6+, mocks 1.7+ ([tests](https://developer.hashicorp.com/terraform/language/tests)) | `tofu test`, `mock_provider`, per-instance `override_resource` (1.12) ([test](https://opentofu.org/docs/cli/commands/test/)); reads `.tftest.hcl` | Go/TS unit tests with mocks, policy packs (Node.js/Python only), integration tests ([testing](https://www.pulumi.com/docs/iac/concepts/testing/)) |
| Languages | HCL | HCL plus `.tofu` overrides | Go, TypeScript, Python, C#, Java, YAML, Pulumi HCL ([HCL](https://www.pulumi.com/docs/iac/languages-sdks/hcl/), status **(unverified)**) |
| Extras that matter here | Stacks, `terraform query`, actions **(unverified)**: none in the plan | Encryption, `-exclude`, OCI registry, `-json-into` (1.12), `lifecycle { enabled }` (1.11), `destroy = false` (1.12) ([1.12](https://opentofu.org/docs/v1.12/intro/whats-new/)) | Real loops and abstractions, Automation API, ESC |
| mise | `aqua:hashicorp/terraform` | `aqua:opentofu/opentofu` | `aqua:pulumi/pulumi` |

## Pulumi detail

The [RFC](../rfc/0022-iac-tool.md#pulumi) holds the Good and Bad points; these are the facts behind them:

- Encryption: `passphrase` is the closest to a local key, `gcpkms` fits GKE later.
- kind needs a generated local SDK whose version in `Pulumi.yaml` Renovate cannot update **(unverified)** (Talos driver).
- Bad: every pre-commit hook replaced by language tooling (`gofmt`, `golangci-lint`, `tsc`, `eslint`) plus `pulumi preview`; trivy IaC scanning of Pulumi programs not supported **(unverified)**; `PULUMI_CONFIG_PASSPHRASE` comes from Pass like the R2 token (migration driver).
- Bad: DIY backend not transactional and without drift detection; Pulumi Cloud Free (1 user, no resource cap, 25 ESC secrets, [pricing](https://www.pulumi.com/pricing/)) is a SaaS holding the state.
- Rewrite: 545 lines plus `pulumi import --from terraform` of every resource (`pulumi convert` covers 90-95% of most projects, [migration](https://www.pulumi.com/docs/iac/guides/migration/migrating-to-pulumi/from-terraform/)).
- Bad: ESC is a Pulumi Cloud service without Proton Pass integration ([ESC](https://www.pulumi.com/docs/esc/)), self-hosting not described **(unverified)**; it overlaps [RFC 0020](https://github.com/gsuquet/infra/pull/4) and does not replace `pass-cli`.
- Readability: with rendered manifests the IaC layer is about four resources per cluster plus three Helm installs; `pulumi preview --diff` is less common than plan output and Go/TS need a build step before an agent can check them, while HCL keeps one declarative format next to the rendered YAML, readable without a language toolchain.

## kind provider options

The choice does not depend on the IaC tool, every one is on both registries:

| Option | registry.opentofu.org | Notes |
|---|---|---|
| `tehcyx/kind` | 0.13.0 (`providers/t/tehcyx/kind.json` in [opentofu/registry](https://github.com/opentofu/registry)) | Plan default, same version as registry.terraform.io |
| `kyma-incubator/kind` | 0.0.11 | Stale; `tehcyx/kind` started as its fork **(unverified)** |
| `unicell/kind` | 0.0.2-u2 | Stale |
| `kind create cluster --config` from the mise task | Not applicable | IaC starts at bootstrap |
