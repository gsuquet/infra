# Research: Terraform vs OpenTofu vs Pulumi

Study D of the platform plan. Question: which infrastructure-as-code (IaC) tool should `infra` use for the
cluster roots (`clusters/<name>/`), the bootstrap modules and the landing zones?
Decision record: [ADR 0022](../adr/0022-iac-tool.md).

Researched on 2026-11-18.
Claims marked **(unverified)** come from prior knowledge and could not be confirmed on an allowed documentation
domain during the study. Every other claim links to its source.

## Scope of the IaC layer

The plan keeps the IaC layer small. It decides how much a general-purpose language can bring:

- Terraform installs only the cluster, the Gateway API CRDs, Cilium and Argo CD (from `rendered/argocd`).
  Argo CD adopts these and installs everything else from rendered manifests.
- Cluster roots: kind (local state), Talos on Raspberry Pis and local servers, GKE.
- Landing zones: `landing-zone/cloudflare` (exists, 545 lines of HCL including its `domain` module, on R2 state),
  `landing-zone/gcp` (planned).
- Providers: `siderolabs/talos`, `tehcyx/kind` (or an alternative), `hashicorp/helm`, `hashicorp/kubernetes`,
  `hashicorp/google`, `cloudflare/cloudflare` 5.x.
- Credentials come from Proton Pass through `pass-cli run`. `terraform plan` runs locally, never in CI.

The secrets in state are the main risk. A Talos cluster has machine secrets (cluster CA, etcd CA, bootstrap
tokens) and an admin kubeconfig. If Terraform stores them, the R2 bucket holds the keys to the cluster.
R2 encrypts objects at rest on the server side, but anyone with the state token can read them, and R2 has
no object versioning (see `landing-zone/cloudflare/README.md`).

## Comparison

| Criterion | Terraform 1.17 | OpenTofu 1.13 | Pulumi (Go / TypeScript) |
|---|---|---|---|
| License | BSL 1.1 since 1.6 **(unverified)**. Use for a personal repo is allowed; the restriction targets competing hosted products **(unverified)**. Providers stay MPL-2.0 **(unverified)**. | MPL-2.0 ([LICENSE](https://github.com/opentofu/opentofu/blob/main/LICENSE)), Linux Foundation project ([FAQ](https://opentofu.org/faq/)). | Apache-2.0 for the CLI and SDKs ([LICENSE](https://github.com/pulumi/pulumi/blob/master/LICENSE)). Pulumi Cloud is a proprietary SaaS. |
| Latest version | 1.17.x ([upgrade guide](https://developer.hashicorp.com/terraform/language/upgrade-guides)) | 1.13.9, 2026-11-05 ([releases](https://github.com/opentofu/opentofu/releases)) | CLI 3.276.0 (`mise ls-remote pulumi`) |
| Ephemeral resources | Yes ([ephemeral block](https://developer.hashicorp.com/terraform/language/block/ephemeral)); 1.10+ per the Talos provider guide | Yes, 1.11+ ([1.11 what's new](https://opentofu.org/docs/v1.11/intro/whats-new/)) | No equivalent concept found in the docs. Secret outputs are encrypted in state instead (see below). |
| Write-only arguments | Yes, 1.11+ ([write-only](https://developer.hashicorp.com/terraform/language/resources/ephemeral/write-only)) | Yes, 1.11+ ([ephemerality](https://opentofu.org/docs/language/ephemerality/)) | Not documented. Whether the bridge maps `*_wo` attributes is **(unverified)**. |
| S3/R2 backend, native lock file | `use_lockfile`, opt-in; DynamoDB locking deprecated ([S3 backend](https://developer.hashicorp.com/terraform/language/settings/backends/s3)) | `use_lockfile` since 1.10, same `skip_*` and `use_path_style` options ([S3 backend](https://opentofu.org/docs/language/settings/backends/s3/), [1.10](https://opentofu.org/docs/v1.10/intro/whats-new/)). The current `backend.tf` should work unchanged **(unverified, not run)**. | DIY S3 backend with `endpoint=` and `s3ForcePathStyle=` query parameters, file lock under `locks/` on by default ([DIY backend](https://www.pulumi.com/docs/iac/operations/stack-management/using-a-diy-backend/)). Not transactional: "cannot transparently recover from certain kinds of partial failures" ([state](https://www.pulumi.com/docs/iac/concepts/state-and-backends/)). |
| Client-side state encryption | None. Only backend encryption at rest **(unverified: no such feature in the docs read)**. | Yes, since 1.7: state **and** plan files, AES-GCM, key providers `pbkdf2` (passphrase), `aws_kms`, `gcp_kms`, `azure_vault`, `openbao`, `external`; `fallback` for migration, `enforced = true`, config through `TF_ENCRYPTION` ([state encryption](https://opentofu.org/docs/language/state/encryption/)). | Per-value: secret values are encrypted in state with the stack secrets provider (`passphrase`, `awskms`, `gcpkms`, `azurekeyvault`, `hashivault`, Pulumi Cloud default) ([secrets](https://www.pulumi.com/docs/iac/concepts/secrets/)). The rest of the state is plain text. Passphrase from `PULUMI_CONFIG_PASSPHRASE[_FILE]` ([env vars](https://www.pulumi.com/docs/iac/cli/environment-variables/)). |
| Provider registry | registry.terraform.io: talos 0.12.0 (partner), kind 0.13.0 (community) | registry.opentofu.org: talos, kind, helm, kubernetes, google, cloudflare all present ([opentofu/registry](https://github.com/opentofu/registry), checked with `gh api`); same provider binaries | Native: `kubernetes`, `google`/`gcp`. Bridged: cloudflare v6.24.0 = upstream 5.29.0, lag of days ([releases](https://github.com/pulumi/pulumi-cloudflare/releases)). Talos: community `@pulumiverse/talos` ([registry](https://www.pulumi.com/registry/packages/talos/)); its release lag and bridge status are **(unverified)**. kind: no registry package; generate a local SDK with `pulumi package add terraform-provider tehcyx/kind` ([any TF provider](https://www.pulumi.com/docs/iac/concepts/providers/any-terraform-provider/)). |
| Provider-defined functions | Yes **(unverified version)** | Yes, since 1.7 ([functions](https://opentofu.org/docs/language/functions/)) | Not applicable: use the host language. |
| Testing | `terraform test` (1.6+), mocks (1.7+) ([tests](https://developer.hashicorp.com/terraform/language/tests)) | `tofu test`, `mock_provider`, `override_resource` incl. per-instance (1.12) ([test](https://opentofu.org/docs/cli/commands/test/)); reads `.tftest.hcl` | Unit tests with mocks in Go/TS, property tests (policy packs, Node.js/Python only), integration tests ([testing](https://www.pulumi.com/docs/iac/concepts/testing/)) |
| Languages | HCL | HCL (plus `.tofu` overrides) | Go, TypeScript, Python, C#, Java, YAML, and Pulumi HCL ([HCL](https://www.pulumi.com/docs/iac/languages-sdks/hcl/), status **(unverified)**) |
| Tool-only extras that matter here | Stacks, `terraform query`, actions **(unverified)**: none of them is in the plan | Encryption, `-exclude`, OCI registry, `-json-into` (1.12, human plus JSON plan in one run) ([1.12](https://opentofu.org/docs/v1.12/intro/whats-new/)), `lifecycle { enabled }` (1.11), `destroy = false` (1.12) | Real loops/abstractions, Automation API, ESC |
| mise | `aqua:hashicorp/terraform` | `aqua:opentofu/opentofu` | `aqua:pulumi/pulumi` (`mise registry <tool>`) |

## Talos secrets: the deciding feature

The Talos provider 0.12.0 has ephemeral resources for `machine_secrets`, `machine_configuration`,
`client_configuration`, `cluster_kubeconfig` and `cluster_health`, and write-only inputs on
`talos_machine_configuration_apply` (`client_configuration_wo`, `machine_configuration_input_wo`)
([provider docs index](https://registry.terraform.io/v2/provider-docs?filter[provider-version]=109978&page[size]=100),
[ephemeral guide](https://registry.terraform.io/v2/provider-docs/13749226)). The guide says:

- the ephemeral `talos_machine_secrets` must be stored in a secret manager on first creation and read back
  on each run ("Do not use `ephemeral "talos_machine_secrets"` without also storing them in a secret manager");
- Terraform 1.11+ and OpenTofu 1.11+ support the full pattern; OpenTofu 1.10 does not.

So two ways keep Talos secrets safe, and they combine:

1. **Out of state** (Terraform or OpenTofu): ephemeral resources plus write-only arguments. This needs the
   secret backend from the open secrets study, reachable by Terraform at plan time. Each provider still has
   resources without write-only variants (the cloudflare README lists OAuth `client_secret` in 5.28.1),
   so some secrets end in state anyway.
2. **Encrypted state** (OpenTofu only): everything that still lands in state or in a saved plan is encrypted
   on the client before it reaches R2. This also covers kind and GKE kubeconfigs, the Cilium and Argo CD
   Helm release values, and any provider that has no write-only argument yet.

Pulumi offers a third way: per-value secret encryption, on by default when the provider marks the field as
secret. It does not cover non-secret-marked fields, and the plan relies on a community bridge for Talos.

## Pulumi specifics

- **Languages.** Go and TypeScript are first-class. With the rendered manifests pattern, the IaC layer is
  about four resources per cluster plus three Helm installs: a general-purpose language adds little.
- **Backend.** Pulumi Cloud Free: 1 user, no resource cap, basic ESC (25 secrets) ([pricing](https://www.pulumi.com/pricing/)).
  It is a new SaaS dependency that holds the state. The DIY R2 backend avoids it but loses transactional
  checkpoints and drift detection.
- **Secrets providers.** `passphrase` is the closest to an age-style local key; `gcpkms` fits GKE later.
- **ESC.** Pulumi Cloud service. Integrations include AWS, Azure, GCP secret managers, Vault and 1Password;
  Proton Pass is not listed ([ESC](https://www.pulumi.com/docs/esc/)). Self-hosting is not described there
  **(unverified)**. It overlaps with the open secrets study and would not replace `pass-cli`.
- **Bridged providers.** cloudflare follows upstream within days. Talos depends on the `pulumiverse`
  community org. kind needs a generated local SDK, and Renovate cannot update the wrapped provider version
  in `Pulumi.yaml` **(unverified)**.
- **Migration.** `pulumi convert --from terraform` converts 90-95% of most projects; `pulumi import --from terraform`
  imports state ([migration](https://www.pulumi.com/docs/iac/guides/migration/migrating-to-pulumi/from-terraform/)).
  Both mean a rewrite and an import for the landing zone.

## Tooling impact

| Tool | Terraform | OpenTofu | Pulumi |
|---|---|---|---|
| pre-commit-terraform (`fmt`, `validate`, `providers_lock`, `tflint`, `trivy`, `tfupdate`) | Works today | Hooks accept a binary override (`--tf-path` / `PCT_TFPATH`) **(unverified)**. `tofu init` records all-platform checksums since 1.12, so `providers_lock` is optional. | All replaced by language tooling (`gofmt`, `golangci-lint`, `tsc`, `eslint`) and `pulumi preview` |
| tflint | Supported | Plain HCL lints; the `encryption` block and `.tofu` files are not officially supported **(unverified)** | Not applicable |
| trivy | Supported | HCL scanned the same; `encryption` block not understood **(unverified)** | IaC scanning of Pulumi programs not supported **(unverified)** |
| terraform-docs | Supported | Works on HCL **(unverified)** | Not applicable |
| tfupdate | Supported | Works on HCL; registry choice **(unverified)** | Not applicable |
| Renovate | `terraform` manager | Same manager, files `*.tf` and `*.tofu`; set `registryUrls: ["https://registry.opentofu.org"]` with a `packageRule` ([manager](https://docs.renovatebot.com/modules/manager/terraform/)). The `required_version` update source for OpenTofu is not documented: drop the exact `required_version` pin or add a rule. | `gomod` / `npm` for SDKs; bridged local SDK versions in `Pulumi.yaml` not managed **(unverified)** |
| mise | `terraform` | `opentofu` | `pulumi` + Go or Node |
| `pass-cli run` | Unchanged | Unchanged; `TF_ENCRYPTION` or a passphrase variable comes from Pass the same way | Unchanged; `PULUMI_CONFIG_PASSPHRASE` from Pass |

## Migration cost of `landing-zone/cloudflare`

- **OpenTofu.** Swap the mise tool and the `tf` tasks (`terraform` → `tofu`), change `required_version` to an
  OpenTofu version, adjust Renovate and the hook binary, run `tofu init` and `tofu plan` (expect no changes),
  then add encryption with an `unencrypted` fallback and apply once. HCL, modules, lock file format and the
  R2 backend stay. OpenTofu checks `required_version` against its own version, so `"1.17.2"` fails
  **(unverified, not run)**. Rollback: restore state backup, `terraform init` ([migration guide](https://opentofu.org/docs/intro/migration/migration-guide/)).
  Once state is encrypted, rollback to Terraform needs a decrypt step first. Effort: about an hour.
- **Pulumi.** Rewrite 545 lines in Go or TypeScript (or keep HCL with Pulumi HCL), import every resource,
  replace all hooks and the Renovate rules, rewrite the R2 bootstrap story. Effort: days.
- **Stay on Terraform.** No cost now. Talos secrets stay out of state only where write-only arguments exist,
  and the rest relies on R2 server-side encryption plus the state token scope.

## Agent-friendliness

- `terraform plan` / `tofu plan` text output is the most common IaC diff format; agents and reviewers read it well.
  `tofu plan -json-into=plan.json` gives the human output and a JSON file in one run.
- `pulumi preview --diff` is readable but less common, and a Go/TS program needs a build step before an agent can check it.
- An encrypted saved plan (OpenTofu) cannot be read by a tool without the key. Plans stay local in this repo, so
  this matters only if a plan-review CI job is added later.
- HCL keeps one declarative format next to the rendered YAML; a reviewer reads both without a language toolchain.

## Recommendation

**Move to OpenTofu now, before the cluster roots exist.**

1. Client-side state and plan encryption is the only feature that protects every secret in state, including
   the ones a provider cannot make write-only. Talos machine secrets and kubeconfigs make this a real need.
2. OpenTofu 1.11+ has ephemeral resources and write-only arguments, which the Talos provider supports, so
   nothing in the plan needs Terraform 1.17.
3. MPL-2.0 under the Linux Foundation removes the license question for a public repo, now and later.
4. The migration is cheap today (one root, 545 lines) and only grows as `clusters/` and `modules/` fill up.
5. HCL, the providers, the R2 backend and most hooks stay; the change is mostly the binary name.

**Reject Pulumi.** The IaC layer is small and declarative by design; Talos and kind would sit on a community
bridge and a generated SDK; the DIY backend is weaker than OpenTofu's S3 backend; the tooling and the landing
zone need a rewrite; ESC duplicates the open secrets study.

Key provider for encryption: start with `pbkdf2` (passphrase in Proton Pass, read by `pass-cli run` into
`TF_ENCRYPTION`), with `enforced = true`. Move to `gcp_kms` for GKE roots when `landing-zone/gcp` exists.
Use one passphrase or key per state file, as the OpenTofu docs advise.

## Risks

- Losing the passphrase makes the state unrecoverable. R2 has no versioning. Keep the passphrase in Pass
  and a backup copy offline.
- OpenTofu follows Terraform features with a lag (1.13 vs 1.17). New Terraform-only features will not arrive.
- tflint and trivy are Terraform-first: OpenTofu-only syntax (`encryption` block) may need an exclusion or a
  `.tofu` file. Test before the switch.
- Provider docs and examples target Terraform; `required_version` constraints in third-party modules can name
  Terraform versions.

## Open questions

1. Does the owner accept OpenTofu with a `pbkdf2` passphrase in Proton Pass as the first key provider, or wait
   for the secrets study and start with OpenBao or `gcp_kms`?
2. Encrypt the kind local state too (uniform `enforced = true`), or leave it plain for speed?
3. Keep `.tf` files (both tools can read them) or allow `.tofu` files for OpenTofu-only blocks?
4. Where are Talos machine secrets stored after first creation? This depends on the secrets study: the
   ephemeral pattern needs a backend that Terraform/OpenTofu can read at plan time.
5. Run a real `tofu init` + `plan` on `landing-zone/cloudflare` (with the read token) to confirm no changes and
   the `required_version` behavior before the switch PR.
6. Check tflint, trivy and tfupdate behavior with an `encryption` block before committing to it.
