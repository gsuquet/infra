# Research: Terraform vs OpenTofu vs Pulumi

Study D of the platform plan. Question: which infrastructure-as-code (IaC) tool should `infra` use for the
cluster roots (`clusters/<name>/`), the bootstrap modules and the landing zones?
Decision record: [ADR 0022](../adr/0022-iac-tool.md).

Researched on 2026-11-18, revised on 2026-11-19 after review.
Claims marked **(unverified)** come from prior knowledge and could not be confirmed on an allowed documentation
domain or by a local test during the study. Every other claim links to its source or names the local test.

## Scope of the IaC layer

The plan keeps the IaC layer small. It decides how much a general-purpose language can bring:

- Terraform installs only the cluster, the Gateway API CRDs, Cilium and Argo CD (from `rendered/argocd`).
  Argo CD adopts these and installs everything else from rendered manifests.
- Cluster roots: kind (local state, ADR 0018), Talos on Raspberry Pis and local servers, GKE (both on R2 state).
- Landing zones: `landing-zone/cloudflare` (exists, 545 lines of HCL including its `domain` module, on R2 state),
  `landing-zone/gcp` (planned).
- Providers: `siderolabs/talos`, `tehcyx/kind` (or an alternative, see [kind provider options](#kind-provider-options)),
  `hashicorp/helm`, `hashicorp/kubernetes`, `hashicorp/google`, `cloudflare/cloudflare` 5.x.
- Credentials come from Proton Pass through `pass-cli run`. `terraform plan` runs locally, never in CI.

Secrets in state are the main risk; [Threat model](#threat-model-state-secrets) below says which ones remain and
who can read them.

## Comparison

| Criterion | Terraform 1.17 | OpenTofu 1.13 | Pulumi (Go / TypeScript) |
|---|---|---|---|
| License | BSL 1.1 since 1.6 **(unverified)**. Use in a public repository used individually and non-commercially is allowed; the restriction targets competing hosted products **(unverified)**. Providers stay MPL-2.0 **(unverified)**. | MPL-2.0 ([LICENSE](https://github.com/opentofu/opentofu/blob/main/LICENSE)), Linux Foundation project ([FAQ](https://opentofu.org/faq/)). | Apache-2.0 for the CLI and SDKs ([LICENSE](https://github.com/pulumi/pulumi/blob/master/LICENSE)). Pulumi Cloud is a proprietary SaaS. |
| Latest version | 1.17.x ([upgrade guide](https://developer.hashicorp.com/terraform/language/upgrade-guides)) | 1.13.9, 2026-11-05 ([releases](https://github.com/opentofu/opentofu/releases)) | CLI 3.276.0 (`mise ls-remote pulumi`) |
| Ephemeral resources | Yes ([ephemeral block](https://developer.hashicorp.com/terraform/language/block/ephemeral)); 1.10+ per the Talos provider guide | Yes, 1.11+ ([1.11 what's new](https://opentofu.org/docs/v1.11/intro/whats-new/)) | No equivalent concept found in the docs. Secret outputs are encrypted in state instead (see below). |
| Write-only arguments | Yes, 1.11+ ([write-only](https://developer.hashicorp.com/terraform/language/resources/ephemeral/write-only)): never stored in state or plan | Yes, 1.11+ ([ephemerality](https://opentofu.org/docs/language/ephemerality/)): never stored in state or plan | Supported, but **not kept out of state**: the initial value "gets written to Pulumi state inputs as a Secret", and Pulumi "will not detect or show diffs on these fields" ([write-only fields](https://www.pulumi.com/docs/iac/concepts/secrets/write-only-fields/)). |
| Version pin in code | `terraform { required_version }` | `language { compatible_with { opentofu = "..." } }`, top-level block, 1.12+ ([settings](https://opentofu.org/docs/language/settings/)). Tested with 1.13.9: `"99.0.0"` fails with "Incompatible module". `required_version` is **not** enforced: `tofu validate` passes with `required_version = "99.0.0"` (local test). | `requiredVersion` in `Pulumi.yaml` **(unverified)** |
| S3/R2 backend, native lock file | `use_lockfile`, opt-in; DynamoDB locking deprecated ([S3 backend](https://developer.hashicorp.com/terraform/language/settings/backends/s3)) | `use_lockfile` since 1.10, same `skip_*` and `use_path_style` options ([S3 backend](https://opentofu.org/docs/language/settings/backends/s3/), [1.10](https://opentofu.org/docs/v1.10/intro/whats-new/)). `tofu init -backend=false` + `validate` pass on the current root (local test); a real backend init was not run. | DIY S3 backend with `endpoint=` and `s3ForcePathStyle=` query parameters, file lock under `locks/` on by default ([DIY backend](https://www.pulumi.com/docs/iac/operations/stack-management/using-a-diy-backend/)). Not transactional: "cannot transparently recover from certain kinds of partial failures" ([state](https://www.pulumi.com/docs/iac/concepts/state-and-backends/)). |
| Client-side state encryption | None. Only backend encryption at rest **(unverified: no such feature in the docs read)**. | Yes, since 1.7: state **and** plan files, local and remote, AES-GCM, key providers `pbkdf2` (passphrase), `aws_kms`, `gcp_kms`, `azure_vault`, `openbao`, `external`; `fallback` for migration, `enforced = true`; configuration in code and/or `TF_ENCRYPTION`, the environment overriding code on conflict ([state encryption](https://opentofu.org/docs/language/state/encryption/)). | Per-value: secret values are encrypted in state with the stack secrets provider (`passphrase`, `awskms`, `gcpkms`, `azurekeyvault`, `hashivault`, Pulumi Cloud default) ([secrets](https://www.pulumi.com/docs/iac/concepts/secrets/)). The rest of the state is plain text. Passphrase from `PULUMI_CONFIG_PASSPHRASE[_FILE]` ([env vars](https://www.pulumi.com/docs/iac/cli/environment-variables/)). |
| Lock file | `.terraform.lock.hcl`, addresses `registry.terraform.io/...` | Same file name and format, but `tofu init` **rewrites** it: header "maintained automatically by \"tofu init\"", address `registry.opentofu.org/cloudflare/cloudflare`, `h1:` hashes added (8 on the cloudflare root); `zh:` hashes kept, same binary (local test, 1.13.9) | `go.sum` / `package-lock.json` for SDKs; plugin versions not locked **(unverified)** |
| Provider registry | registry.terraform.io: talos 0.12.0 (partner, 2026-09-21), kind 0.13.0 (community) | registry.opentofu.org: talos, kind, helm, kubernetes, google, cloudflare all present ([opentofu/registry](https://github.com/opentofu/registry), checked with `gh api`); same provider binaries | Native: `kubernetes`, `google`/`gcp`. Bridged: cloudflare v6.24.0 = upstream 5.29.0, lag of days ([releases](https://github.com/pulumi/pulumi-cloudflare/releases)). Talos: community `pulumiverse` package **v0.8.1, published 2026-07-29** ([API docs](https://www.pulumi.com/registry/packages/talos/api-docs/)), before upstream 0.12.0 (2026-09-21, [registry.terraform.io versions](https://registry.terraform.io/v2/providers/siderolabs/talos/provider-versions)). Its `machine` module has only `Bootstrap`, `ConfigurationApply`, `Secrets` ([machine module](https://www.pulumi.com/registry/packages/talos/api-docs/machine/)): no `talos_machine` / `talos_cluster` resources and none of their `_wo` inputs. kind: no registry package; generate a local SDK with `pulumi package add terraform-provider tehcyx/kind` ([any TF provider](https://www.pulumi.com/docs/iac/concepts/providers/any-terraform-provider/)). |
| Provider-defined functions | Yes **(unverified version)** | Yes, since 1.7 ([functions](https://opentofu.org/docs/language/functions/)) | Not applicable: use the host language. |
| Testing | `terraform test` (1.6+), mocks (1.7+) ([tests](https://developer.hashicorp.com/terraform/language/tests)) | `tofu test`, `mock_provider`, `override_resource` incl. per-instance (1.12) ([test](https://opentofu.org/docs/cli/commands/test/)); reads `.tftest.hcl` | Unit tests with mocks in Go/TS, property tests (policy packs, Node.js/Python only), integration tests ([testing](https://www.pulumi.com/docs/iac/concepts/testing/)) |
| Languages | HCL | HCL (plus `.tofu` overrides) | Go, TypeScript, Python, C#, Java, YAML, and Pulumi HCL ([HCL](https://www.pulumi.com/docs/iac/languages-sdks/hcl/), status **(unverified)**) |
| Tool-only extras that matter here | Stacks, `terraform query`, actions **(unverified)**: none of them is in the plan | Encryption, `-exclude`, OCI registry, `-json-into` (1.12, human plus JSON plan in one run) ([1.12](https://opentofu.org/docs/v1.12/intro/whats-new/)), `lifecycle { enabled }` (1.11), `destroy = false` (1.12) | Real loops/abstractions, Automation API, ESC |
| mise | `aqua:hashicorp/terraform` | `aqua:opentofu/opentofu` | `aqua:pulumi/pulumi` (`mise registry <tool>`) |

## Talos secrets

The Talos provider 0.12.0 has ephemeral resources for `machine_secrets`, `machine_configuration`,
`client_configuration`, `cluster_kubeconfig` and `cluster_health`
([provider docs index](https://registry.terraform.io/v2/provider-docs?filter[provider-version]=109978&page[size]=100),
[ephemeral guide](https://registry.terraform.io/v2/provider-docs/13749226)), and write-only inputs on three resources:

| Resource | Write-only inputs | Source |
|---|---|---|
| `talos_machine` | `machine_configuration_wo`, `client_configuration_wo`, `kubeconfig_wo` | [docs 13749231](https://registry.terraform.io/v2/provider-docs/13749231) |
| `talos_cluster` | `client_configuration_wo` | [docs 13749228](https://registry.terraform.io/v2/provider-docs/13749228) |
| `talos_machine_configuration_apply` | `client_configuration_wo`, `machine_configuration_input_wo` | [docs index](https://registry.terraform.io/v2/provider-docs?filter[provider-version]=109978&page[size]=100) |

The Talos study ([PR #9](https://github.com/gsuquet/infra/pull/9), `docs/research/talos-on-raspberry-pi.md`) builds
the module on `talos_machine` and `talos_cluster`; this study uses the same resources.
The ephemeral guide says:

- the ephemeral `talos_machine_secrets` must be stored in a secret manager on first creation and read back
  on each run ("Do not use `ephemeral "talos_machine_secrets"` without also storing them in a secret manager");
- Terraform 1.11+ and OpenTofu 1.11+ support the full pattern; OpenTofu 1.10 does not.

Two mechanisms keep Talos secrets safe, and they combine:

1. **Out of state** (Terraform or OpenTofu): ephemeral resources plus write-only arguments. With the full pattern
   (option B of the Talos study), Talos state holds hashes and IDs only. This needs the secrets backend from the
   open secrets study, reachable at plan time.
2. **Encrypted state** (OpenTofu only): whatever still lands in state or in a saved plan is encrypted on the
   client. This is defense in depth, see the threat model.

Pulumi keeps write-only values in state as encrypted secrets, and its Talos package does not have the
resources above.

## Threat model: state secrets

### What remains in state, per root

| Root | State location | Secrets left in state with the ephemeral / `_wo` pattern | Without it |
|---|---|---|---|
| `landing-zone/cloudflare` | R2 | None by design: "No secret value is created by a resource of this configuration" (`landing-zone/cloudflare/README.md`); OAuth IdP `client_secret` kept out of Terraform for that reason | Same |
| `clusters/<kind>` | Local disk (ADR 0018) | kind provider kubeconfig and client key (no write-only variant known) **(unverified)** | Same |
| `clusters/<talos>` | R2 | Hashes and IDs (Talos study, option B). Plus anything the cluster root generates itself, e.g. the service account signing key of ADR 0020 option G ([PR #4](https://github.com/gsuquet/infra/pull/4)) if it is generated in Terraform | Cluster CA, etcd CA, bootstrap tokens, admin kubeconfig, talosconfig |
| `clusters/<gke>` | R2 | Cluster CA (public). The Google access token used to configure the helm/kubernetes providers, if read with the `google_client_config` data source: data source results are stored in state; short-lived (about one hour) **(unverified: whether an ephemeral variant exists)** | Same |
| Helm releases (Cilium, Argo CD) | With the cluster | Release values; no secret planned in them | Same |

So with the full ephemeral pattern, the R2 states hold almost no long-lived secret. Encryption matters when
that pattern is not used (Talos options A/C), when a root generates a key (ADR 0020 option G), or when a provider
lacks a write-only variant.

### Who encryption stops

`pbkdf2` with the passphrase in the same Proton Pass session as the R2 token (same `pass-cli run` env file):

| Adversary | Reads state today | With `pbkdf2` encryption |
|---|---|---|
| Leaked R2 state token alone (shell history, log, over-scoped token) | Yes | **No** |
| Cloudflare-side access to the bucket, R2 data at rest | Yes | **No** |
| A saved plan file left on disk or attached somewhere | Yes | **No** (plans are encrypted too) |
| Anyone holding the owner's `pass-cli` session | Yes | **Yes**: same session holds the passphrase |
| Agents: they run the same mise tasks as the same OS user (ADR 0020, PR #4) | Yes | **Yes**: `tofu state pull` / `tofu show` decrypt transparently |

Encryption with a passphrase from the same session does **not** close the agent read path that ADR 0020 names
("production Talos Terraform state out of agents' reach", its open question 10). Only a key or credential that
agents cannot reach does:

- **Separate Pass vault.** The passphrase (or the production R2 token) in a Proton Pass vault behind a separate
  login with re-authentication per use, read only by person-run tasks (`cluster:up` / `cluster:plan` of
  production Talos roots). Whether `pass-cli` supports this is **(unverified)**, as in ADR 0020.
- **`gcp_kms`.** The key provider calls Cloud KMS with an identity that holds `roles/cloudkms.cryptoKeyEncrypterDecrypter`
  on that key, and the agents' gcloud identity does not. Needs `landing-zone/gcp`.
- **Separate R2 credential only** (no encryption): closes the agent path as well, but not the Cloudflare-side path.

Any of these means agents cannot run `plan` on those roots: a person runs them. That matches ADR 0020 question 10.

### Key granularity and backup

The OpenTofu docs advise "a separate key management key for each state file" for the KMS and OpenBao key
providers, not for `pbkdf2` ([state encryption](https://opentofu.org/docs/language/state/encryption/)). `pbkdf2`
has a `salt_length` option (default 32 bytes); whether the salt is random per file is not stated
**(unverified)**. Proposal: one passphrase per environment (one for production roots, one for everything else),
not one per state: each extra passphrase is one more Pass item to lose. Backup: a copy of each passphrase on
paper or an offline medium kept apart from Pass, checked by decrypting a downloaded state once after creation.

## Pulumi specifics

- **Languages.** Go and TypeScript are first-class. With the rendered manifests pattern, the IaC layer is
  about four resources per cluster plus three Helm installs: a general-purpose language adds little.
- **Backend.** Pulumi Cloud Free: 1 user, no resource cap, basic ESC (25 secrets) ([pricing](https://www.pulumi.com/pricing/)).
  It is a new SaaS dependency that holds the state. The DIY R2 backend avoids it but loses transactional
  checkpoints and drift detection.
- **Secrets providers.** `passphrase` is the closest to an age-style local key; `gcpkms` fits GKE later.
- **Write-only fields.** Stored in state inputs as secrets, and changes are not diffed
  ([write-only fields](https://www.pulumi.com/docs/iac/concepts/secrets/write-only-fields/)). Talos secrets
  would sit in state, encrypted per value.
- **ESC.** Pulumi Cloud service. Integrations include AWS, Azure, GCP secret managers, Vault and 1Password;
  Proton Pass is not listed ([ESC](https://www.pulumi.com/docs/esc/)). Self-hosting is not described there
  **(unverified)**. It overlaps with the open secrets study and would not replace `pass-cli`.
- **Bridged providers.** cloudflare follows upstream within days. Talos lags: pulumiverse v0.8.1 (2026-07-29)
  predates upstream 0.12.0 (2026-09-21) and has no `talos_machine` / `talos_cluster`. kind needs a generated
  local SDK, and Renovate cannot update the wrapped provider version in `Pulumi.yaml` **(unverified)**.
- **Migration.** `pulumi convert --from terraform` converts 90-95% of most projects; `pulumi import --from terraform`
  imports state ([migration](https://www.pulumi.com/docs/iac/guides/migration/migrating-to-pulumi/from-terraform/)).
  Both mean a rewrite and an import for the landing zone.

## kind provider options

| Option | registry.opentofu.org | Notes |
|---|---|---|
| `tehcyx/kind` | Yes, 0.13.0 (`providers/t/tehcyx/kind.json` in [opentofu/registry](https://github.com/opentofu/registry)) | The plan's default; same version as registry.terraform.io |
| `kyma-incubator/kind` | Yes, latest 0.0.11 | Stale; `tehcyx/kind` started as its fork **(unverified)** |
| `unicell/kind` | Yes, latest 0.0.2-u2 | Stale |
| No provider: `kind create cluster --config` from the mise task, Terraform starts at bootstrap | Not applicable | Keeps the kubeconfig out of state entirely; the cluster is not in a plan. Worth deciding in the cluster-kind module task. |

The choice does not depend on the IaC tool: every listed provider is in both registries. Out of scope here
beyond this table.

## Tooling impact

Local tests on a scratch copy of `landing-zone/cloudflare`, without credentials, with the repo pins
(tflint 0.66.0 and `.tflint.hcl`, trivy 0.76.1, tfupdate 0.10.3) and OpenTofu 1.13.9, with an `encryption`
block (`pbkdf2`, `enforced = true`) and a top-level `language` block added in `.tf` files:

- `tofu init -backend=false` and `tofu validate`: pass.
- tflint: no error on either block (only the expected `terraform_standard_module_structure` /
  `terraform_documented_variables` findings on the test variable).
- `trivy config --exit-code 1`: 0 misconfigurations.
- `tfupdate opentofu -v <v>`: rewrites `required_version`, does **not** touch the `language` block or `.tofu` files.

| Tool | Terraform | OpenTofu | Pulumi |
|---|---|---|---|
| pre-commit-terraform (`fmt`, `validate`, `providers_lock`, `tflint`, `trivy`, `tfupdate`) | Works today | Hooks accept a binary override (`--tf-path` / `PCT_TFPATH`) **(unverified)**. `terraform_providers_lock` must run tofu or be dropped, or it rewrites the lock files back to `registry.terraform.io`. | All replaced by language tooling (`gofmt`, `golangci-lint`, `tsc`, `eslint`) and `pulumi preview` |
| tflint | Supported | Accepts `encryption` and `language` blocks in `.tf` files (tested). `.tofu` files not tested. | Not applicable |
| trivy | Supported | Accepts both blocks, no finding (tested) | IaC scanning of Pulumi programs not supported **(unverified)** |
| terraform-docs | Supported | Works on HCL **(unverified)** | Not applicable |
| tfupdate | Supported | Has an `opentofu` subcommand, but it targets `required_version`, which OpenTofu does not enforce (tested). Drop the hook or limit it to providers. | Not applicable |
| Renovate | `terraform` manager | Same manager, files `*.tf` and `*.tofu`; set `registryUrls: ["https://registry.opentofu.org"]` with a `packageRule` ([manager](https://docs.renovatebot.com/modules/manager/terraform/)). The manager does not manage the `language` block **(unverified: not documented)**: the CLI version moves in mise only unless a regex `customManagers` entry updates `compatible_with` with it. Lock file maintenance is done by Renovate itself, not by calling tofu ([manager](https://docs.renovatebot.com/modules/manager/terraform/)); whether it then writes `registry.opentofu.org` addresses is **(unverified)**. | `gomod` / `npm` for SDKs; bridged local SDK versions in `Pulumi.yaml` not managed **(unverified)** |
| mise | `terraform` | `opentofu` | `pulumi` + Go or Node |
| `pass-cli run` | Unchanged | Unchanged; the passphrase variable or `TF_ENCRYPTION` comes from Pass the same way (see threat model for which vault) | Unchanged; `PULUMI_CONFIG_PASSPHRASE` from Pass |

## Migration cost of `landing-zone/cloudflare`

**OpenTofu**, in one switch PR, every step together (otherwise the lock files flip between registries):

1. mise: replace `terraform` with `opentofu` (lockfile updated); `tf` task and `cluster:*` tasks call `tofu`.
2. Version pin: remove `required_version` (OpenTofu ignores it, local test) and add a top-level
   `language { compatible_with { opentofu = "1.13.9" } }` ([settings](https://opentofu.org/docs/language/settings/)).
   An exact value blocks the next patch release until it is updated: either a Renovate regex `customManagers`
   entry grouped with the mise `opentofu` update, or a range such as `"~> 1.13.9"` (accepted by 1.13.9;
   `"~> 1.13.10"` fails on 1.13.9, local test).
3. Lock files: regenerate both (`landing-zone/cloudflare` and its `modules/domain`) with `tofu init` /
   `tofu providers lock`; review the diff (address, header, `h1:` hashes).
4. pre-commit: point pre-commit-terraform at tofu (`PCT_TFPATH`, **unverified**) or drop `terraform_providers_lock`;
   drop `tfupdate` or limit it to providers.
5. Renovate: `registryUrls` for providers on registry.opentofu.org; rename the "terraform cli" group to match
   `opentofu` / `opentofu/opentofu` in mise plus the `compatible_with` regex manager; check a lock file
   maintenance run.
6. `tofu init` with the R2 backend and a **read-only `tofu plan`** against the state written by Terraform 1.17.2:
   expect no changes. Not run in this study (needs the R2 read token).
7. Then encryption: add the `encryption` block with an `unencrypted` fallback, apply once, set `enforced = true`,
   remove the fallback.

Rollback: restore state backup, `terraform init` ([migration guide](https://opentofu.org/docs/intro/migration/migration-guide/)).
Once state is encrypted, rollback needs a decrypt step first (remove `enforced`, add a fallback).
Effort: about an hour of work **as an estimate only**, until step 6 shows no changes.

**Pulumi.** Rewrite 545 lines in Go or TypeScript (or keep HCL with Pulumi HCL), import every resource,
replace all hooks and the Renovate rules, rewrite the R2 bootstrap story. Effort: days.

**Stay on Terraform.** No cost now. Long-lived secrets stay out of R2 only where the ephemeral / `_wo` pattern
is applied; the rest relies on R2 server-side encryption and the state token scope.

## Agent-friendliness

- `terraform plan` / `tofu plan` text output is the most common IaC diff format; agents and reviewers read it well.
  `tofu plan -json-into=plan.json` gives the human output and a JSON file in one run.
- `pulumi preview --diff` is readable but less common, and a Go/TS program needs a build step before an agent can check it.
- An encrypted saved plan (OpenTofu) cannot be read by a tool without the key. Plans stay local in this repo, so
  this matters only if a plan-review CI job is added later.
- If production roots use a key agents cannot reach, agents cannot plan them: a person runs and pastes the plan.
- HCL keeps one declarative format next to the rendered YAML; a reviewer reads both without a language toolchain.

## Recommendation

**Move to OpenTofu, after a read-only `tofu plan` on `landing-zone/cloudflare` shows no changes, and before the
cluster roots exist.** It is a moderate preference, not a forced one:

1. MPL-2.0 under the Linux Foundation removes the license question for a public repository, now and later.
2. OpenTofu 1.11+ has ephemeral resources and write-only arguments, which the Talos provider supports, so
   nothing in the plan needs Terraform 1.17.
3. Client-side state and plan encryption is defense in depth: it stops a leaked R2 token, Cloudflare-side access
   and stray plan files. It does not stop agents unless the key sits where agents cannot reach it (see threat model).
   The primary control stays the ephemeral / `_wo` pattern, which keeps Talos state free of long-lived secrets on
   either tool.
4. The migration is cheaper today (one root, two lock files) than after `clusters/` and `modules/` fill up, but it
   is not just a binary rename: the version pin, lock files, two hooks and the Renovate rules change.

Staying on Terraform is acceptable if the owner adopts the full ephemeral pattern for Talos and closes ADR 0020
question 10 with a credential agents do not hold.

**Reject Pulumi.** The IaC layer is small and declarative by design; Talos sits on a community package that lags
upstream and lacks `talos_machine` / `talos_cluster`; write-only values still land in state; kind needs a
generated SDK; the DIY backend is weaker than OpenTofu's S3 backend; the tooling and the landing zone need a
rewrite; ESC duplicates the open secrets study.

Key provider for encryption: `pbkdf2`, configured in code with a sensitive passphrase variable and
`enforced = true`; one passphrase per environment. Production passphrase in a Pass vault agents cannot open,
if `pass-cli` allows it. Move to `gcp_kms` with an identity agents do not hold when `landing-zone/gcp` exists.

## Risks

- Losing the passphrase makes the state unrecoverable. R2 has no versioning. Keep each passphrase in Pass
  and a backup copy offline.
- Terraform-only features will not arrive in OpenTofu. The version numbers are independent (OpenTofu 1.13 is not
  "behind" Terraform 1.17 by four releases): compare features, not numbers.
- `tofu plan` against state written by Terraform 1.17.2 has not been tried.
- The `compatible_with` pin is not managed by Renovate or tfupdate out of the box.
- Provider docs and examples target Terraform; third-party modules may carry Terraform-only `required_version`
  constraints (OpenTofu ignores them, so they do not block, but they also do not protect).

## Open questions

1. Does the owner accept OpenTofu with a `pbkdf2` passphrase in Proton Pass as the first key provider, or wait
   for the secrets study and start with OpenBao or `gcp_kms`?
2. Encrypt the kind local state too (uniform `enforced = true`), or leave it plain for speed?
3. Keep `.tf` files only (tested with tflint and trivy) or allow `.tofu` files for OpenTofu-only blocks (not tested)?
4. Where are Talos machine secrets stored after first creation? This depends on the secrets study: the
   ephemeral pattern needs a backend that Terraform/OpenTofu can read at plan time.
5. Run a real `tofu init` + read-only `plan` on `landing-zone/cloudflare` (with the read token) to confirm no
   changes before the switch PR.
6. tflint and trivy: closed (both accept `encryption` and `language` blocks). Still open: the pre-commit-terraform
   tofu override, Renovate lock file maintenance against registry.opentofu.org, terraform-docs.
7. Which vault holds the production passphrase, and does `pass-cli` support a separate login with re-authentication
   (shared with ADR 0020 question 10)?
8. kind: provider (`tehcyx/kind`) or `kind create cluster` from the mise task?
