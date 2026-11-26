# State secrets threat model for RFC 0022

<!-- readability: allow-code R2 -->

This page lists what each root leaves in state and who can read it.
The decision is in [RFC 0022](../rfc/0022-iac-tool.md#decision).

**(unverified)** marks a claim from prior knowledge that no allowed documentation domain or local test confirmed.

## What stays in state

With the ephemeral / `_wo` pattern:

| Root | State | Left in state with the pattern | Without it |
|---|---|---|---|
| `landing-zone/cloudflare` | R2 | None by design ("No secret value is created by a resource of this configuration", `landing-zone/cloudflare/README.md`); OAuth IdP `client_secret` kept out of IaC | Same |
| `clusters/<kind>` | Local disk | kind kubeconfig and client key, no write-only variant known **(unverified)** | Same |
| `clusters/<talos>` | R2 | Hashes and IDs (Talos study option B, [PR #9](https://github.com/gsuquet/infra/pull/9)), plus any key the root generates, such as the service account signing key of [RFC 0020 option G](https://github.com/gsuquet/infra/pull/4) | Cluster CA, etcd CA, bootstrap tokens, admin kubeconfig, talosconfig |
| `clusters/<gke>` | R2 | Cluster CA (public); Google access token if read with the `google_client_config` data source, short-lived (about one hour) **(unverified: whether an ephemeral variant exists)** | Same |
| Helm releases (Cilium, Argo CD) | With the cluster | Release values, no secret planned | Same |

Encryption matters when the pattern is not used ([Talos options A/C](https://github.com/gsuquet/infra/pull/9)), when a root generates a key
([RFC 0020 option G](https://github.com/gsuquet/infra/pull/4)), or when a provider lacks a write-only variant.

## Talos ephemeral resources

Talos 0.12.0 ephemeral resources: `machine_secrets`, `machine_configuration`, `client_configuration`,
`cluster_kubeconfig`, `cluster_health` ([index](https://registry.terraform.io/v2/provider-docs?filter[provider-version]=109978&page[size]=100),
[ephemeral guide](https://registry.terraform.io/v2/provider-docs/13749226)). Write-only inputs:

| Resource | Write-only inputs | Source |
|---|---|---|
| `talos_machine` | `machine_configuration_wo`, `client_configuration_wo`, `kubeconfig_wo` | [docs 13749231](https://registry.terraform.io/v2/provider-docs/13749231) |
| `talos_cluster` | `client_configuration_wo` | [docs 13749228](https://registry.terraform.io/v2/provider-docs/13749228) |
| `talos_machine_configuration_apply` | `client_configuration_wo`, `machine_configuration_input_wo` | [docs index](https://registry.terraform.io/v2/provider-docs?filter[provider-version]=109978&page[size]=100) |

The guide requires storing ephemeral `talos_machine_secrets` in a secret manager on first creation and reading
them back each run; Terraform 1.11+ and OpenTofu 1.11+ support the full pattern, OpenTofu 1.10 does not.

## Who `pbkdf2` encryption stops

Who it stops, with the passphrase in the same Pass session as the R2 token:

| Adversary | Reads state today | With encryption |
|---|---|---|
| Leaked R2 state token alone (shell history, log, over-scoped token) | Yes | **No** |
| Cloudflare-side access, R2 data at rest | Yes | **No** |
| A saved plan file left on disk or attached somewhere | Yes | **No** |
| Anyone holding the owner's `pass-cli` session | Yes | **Yes** |
| Agents running mise tasks as the same OS user | Yes | **Yes**: `tofu state pull` / `tofu show` decrypt transparently |

Only a key agents cannot reach closes the agent path ([RFC 0020 question 10](https://github.com/gsuquet/infra/pull/4)): a separate Pass vault with
re-authentication per use **(unverified: `pass-cli` support)**, `gcp_kms` with an identity agents do not hold
(`roles/cloudkms.cryptoKeyEncrypterDecrypter`, needs `landing-zone/gcp`), or a separate R2 credential (closes the
agent path, not the Cloudflare-side one). Then a person runs `plan` on those roots and pastes it.
