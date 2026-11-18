# Secrets backend study

Status: input for [ADR 0020](../adr/0020-secrets-backend.md). Research date: 2026-11-18.

This study compares the backends that can sit behind the External Secrets Operator (ESO) store `secrets` that every namespace of every cluster uses. The platform plan fixes the store name so that the backend can change. It leaves the backend open.

Facts marked **(verified)** were checked on the date above against the source linked next to them. Facts marked **(unverified)** come from prior knowledge or from a source outside the allowed documentation domains. Check them before you build on them.

## Constraints

| Constraint | Consequence for the backend |
| --- | --- |
| `gsuquet/infra` and `gsuquet/gitops` are public. | Anything committed is public forever, ciphertext included. A key that leaks in ten years opens every old ciphertext in the history. |
| Agents write the code but must never read or write a value. Agents run as the owner's OS user. | Agent rules are rules, not controls. A real control is an identity that agents do not hold. |
| N clusters: kind (many, ephemeral), Talos on Raspberry Pis and local servers, GKE. | The cost of one secret change must not grow with N, or it must stay small. |
| kind is ephemeral and must work offline. | kind cannot depend on a credential, a network, or a person at the keyboard. |
| Each cluster runs its own Argo CD and renders manifests to plain YAML in Git. | No value can go through the render step or the Argo CD repository server. |
| Terraform installs only the cluster, Gateway API CRDs, Cilium and Argo CD. | The backend credential (if any) is either created by Terraform without a value in state, or not needed. |
| The owner's human store is Proton Pass. Terraform credentials already come from `pass-cli run` with `pass://` references (`landing-zone/cloudflare/pass/*.env`). | A human-to-backend step already exists and can be reused. |

## Criteria

1. **Public repo**: what is in Git, and what a future key leak exposes.
2. **Agent isolation**: can the owner write values through an identity that agents do not use?
3. **Write cost for N clusters**: the work for one new or rotated value used by N clusters.
4. **kind**: works on an ephemeral, offline cluster with no person present.
5. **Bootstrap credential per cluster** (secret zero): what each cluster needs before ESO can read.
6. **Outage behaviour**: what breaks when the backend is unreachable.
7. **Disaster recovery and key loss**: what is lost if a key, a cluster or an account is lost.
8. **Cost**.
9. **Talos specifics**.
10. **GKE fit**.
11. **Operational complexity**: new stateful services, upgrades, backups.

## Shared facts about ESO

- Provider stability, from the [ESO stability and support page](https://external-secrets.io/latest/introduction/stability-support/) **(verified)**: GCP Secret Manager `stable`, HashiCorp Vault `stable`, Kubernetes `beta`, OpenBao `alpha`, Generic Webhook `alpha`, Bitwarden Secrets Manager `alpha`, 1Password and 1Password SDK `alpha`, Infisical `alpha`, Doppler `alpha`, Keeper `alpha`, Passbolt `alpha`.
- **There is no Proton Pass provider.** It is not in the provider table above **(verified)**. There is no SOPS provider either.
- The [OpenBao page](https://external-secrets.io/latest/provider/openbao/) says ESO talks to OpenBao through the Vault provider; it reports a test with ESO v0.16.1 and OpenBao v2.2.0 **(verified)**. The `alpha` label applies to that pairing, not to the Vault provider code.
- The [fake provider](https://external-secrets.io/latest/provider/fake/) returns static key/value pairs defined in the store manifest. It ignores `property` **(verified)**.
- The [Kubernetes provider](https://external-secrets.io/latest/provider/kubernetes/) needs `get`, `list`, `watch` on `secrets` and `create` on `selfsubjectrulesreviews`. It cannot use the ESO controller's own service account **(verified)**.
- On a failed refresh the `Ready` condition becomes `False` ([ExternalSecret API](https://external-secrets.io/latest/api/externalsecret/), **verified**). The page does not say what happens to the target Secret. ESO keeps the last synced Secret when the provider is unreachable **(unverified)**; `deletionPolicy` applies only when data is removed at the provider **(verified)**.
- The default `refreshInterval` is 1h **(unverified)**.

## Options

### A. SOPS + age, Terraform seeds, ESO Kubernetes provider (homelab model)

Source: `gsuquet/homelab` `docs/explanation/secrets-management.md`.

A person edits one SOPS file per cluster. A separate Terraform root per cluster decrypts it in memory (`ephemeral "sops_file"`), writes each value into a seed Secret in `secret-seeds-<consumer>` through a write-only argument (`data_wo`), and ESO copies it into the consumer namespace through the per-namespace store `secrets` (Kubernetes provider). Only a person runs `secrets:apply`, from a clean checkout of `main`, with a typed confirmation.

| Criterion | Assessment |
| --- | --- |
| Public repo | Ciphertext in Git. A leaked scope key or recovery key opens every past version in the history. Each leak forces a rotation of every value at its issuer. |
| Agent isolation | Weak by construction: same OS user. The production scope key sits on a hardware key with touch, which is a real control for decryption. Values also sit in Proton Pass, so A is exposed to the same `pass-cli` session risk as B (see [Agent read paths](#agent-read-paths)). On Talos, the admin kubeconfig in the cluster state reads the seeds, but only from a network that reaches the API server. |
| Write cost, N clusters | **High.** One SOPS edit per cluster file that holds the value, then one person-run `secrets:apply` per cluster. A value shared by 3 clusters is 3 edits (or a shared file) and 3 applies. |
| kind | Works offline, but a re-created kind has no seeds until a person applies them. In homelab this blocked tests. |
| Bootstrap credential | None in the cluster. The applier needs a kubeconfig with write access to the seed namespaces. |
| Outage | No external dependency at run time. |
| DR / key loss | Lost scope key: the recovery key (offline, paper) decrypts. Lost both: values gone from Git; re-enter from the issuer or from Proton Pass. |
| Cost | Free. |
| Talos | Works. The applier needs network access to each Talos API server. Each value is twice in etcd (seed and consumer). |
| GKE | Works, but ignores the native store and needs a person with cluster credentials per apply. |
| Complexity | High: SOPS rules, age key handling, a separate root per cluster, seed namespaces, a state test, a `secrets:apply` clean-environment script. |

Assessment: correct and careful for one laptop cluster. It does not scale to N clusters, and it duplicates what Proton Pass already does (a human store) with a second human store (SOPS files).

### B. GCP Secret Manager, single store for all clusters (ESO `gcpsm`)

Each value lives once in Secret Manager. Each namespace has its store `secrets` with the `gcpsm` provider. ESO reads with a short-lived federated token; no static key exists.

Authentication, from the [ESO GCP provider page](https://external-secrets.io/latest/provider/google-secrets-manager/) **(verified)**:

- **GKE**: `auth.workloadIdentity` with `serviceAccountRef`. With [Workload Identity Federation for GKE](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) the role can go directly on `principal://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/PROJECT_ID.svc.id.goog/subject/ns/NAMESPACE/sa/KSA_NAME`, with no Google service account **(verified)**.
- **Talos and other self-managed clusters**: `auth.workloadIdentityFederation` with `serviceAccountRef` and `audience` (the full workload identity provider name). ESO gets a Kubernetes token through the TokenRequest API and exchanges it at Google STS. `projectID` must be set (no metadata server). Optional `gcpServiceAccountEmail` for impersonation **(verified)**.
- The [WIF with Kubernetes guide](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes) says the cluster does not need to be reachable from the internet: read the issuer from `/.well-known/openid-configuration`, download `/openid/v1/jwks`, and create the provider with `--jwk-json-path`. The command does not validate the JWKS; a wrong or stale JWKS makes later authentication fail with `Error connecting to the given credential's issuer`. The guide does not cover key rotation **(verified)**.
- The Terraform equivalent is `jwks_json` in the `oidc` block of `google_iam_workload_identity_pool_provider` (RSA and EC keys) ([provider docs](https://raw.githubusercontent.com/hashicorp/terraform-provider-google/main/website/docs/r/iam_workload_identity_pool_provider.html.markdown), **verified**).
- Subject mapping `google.subject=assertion.sub` gives `system:serviceaccount:<ns>:<sa>`; an attribute condition can limit namespaces with CEL on `assertion['kubernetes.io']['namespace']` **(verified)**.

Per-namespace isolation (the reason homelab had one seed namespace per consumer) maps onto IAM: each namespace store uses a service account in its own namespace, so each namespace is its own principal. These IAM bindings hold no values, so agents can write them in Terraform and the owner reviews them.

Granting `roles/secretmanager.secretAccessor` per secret costs O(secrets x namespaces x pools) bindings, and every new tenant `ExternalSecret` (in `gsuquet/gitops`) would need an IAM change in `infra` and a person-run apply. The cheaper shape is one binding per namespace principal with an IAM Condition on a name prefix, for example `resource.name.startsWith("projects/PROJECT_NUMBER/secrets/<tenant>--<namespace>--")`. Secret Manager supports IAM Conditions on resource attributes, `resource.name` is available for secrets and secret versions, and `startsWith()` is supported ([Secret Manager access control](https://docs.cloud.google.com/secret-manager/docs/access-control), [conditions attribute reference](https://docs.cloud.google.com/iam/docs/conditions-attribute-reference), **verified**). The exact `resource.name` format (project number or ID) and whether the condition must be checked against the version name as well are **(unverified)**: test it on the first secret. With a naming convention, the binding count is O(namespaces), and a new `ExternalSecret` under an existing prefix needs no IAM change.

Terraform ownership (proposal, the plan does not fix it yet):

- `landing-zone/gcp` owns the project, the Secret Manager API, the secret objects (no versions), the workload identity pools and the conditional IAM bindings. Everything there holds no value.
- The Talos workload identity provider and its `jwks_json` also live in `landing-zone/gcp`, fed by a public JWKS file committed per cluster (for example `clusters/<name>/jwks.json`) that a `cluster:up` post-step reads from `/openid/v1/jwks`. This keeps the settled bootstrap boundary: the cluster root needs no Google credentials and no live kube API read, and GCP is not a dependency of cluster creation. The cost is a second apply (`landing-zone/gcp`) before ESO on a new Talos cluster turns `Ready`.
- The alternative, the provider in the cluster root, saves that step but widens the bootstrap boundary (Google credentials and a post-bootstrap API read in every Talos `cluster:up`). See the open questions.
- Versions are written by a person-only path, never by `landing-zone/gcp` or a cluster root (see below).

Writing values: Proton Pass stays the human source of truth. A person-run task resolves `pass://` references with `pass-cli run` (the pattern `landing-zone/cloudflare` already uses) and writes a version:

- through Terraform, with `google_secret_manager_secret_version.secret_data_wo` and `secret_data_wo_version` (write-only, not stored in state, [provider docs](https://raw.githubusercontent.com/hashicorp/terraform-provider-google/main/website/docs/r/secret_manager_secret_version.html.markdown), **verified**), fed by `ephemeral = true` variables; a rotation bumps the non-secret `secret_data_wo_version` counter in Git; or
- through `gcloud secrets versions add --data-file=-` from a pipe, with no Terraform state at all **(unverified exact syntax for the pass-cli side)**.

| Criterion | Assessment |
| --- | --- |
| Public repo | **Nothing secret in Git**: only secret names, IAM bindings and the JWKS (public keys). No ciphertext to harvest. |
| Agent isolation | **No better than A by default.** The write side can be a real control: the identity that writes versions holds `roles/secretmanager.secretVersionAdder` only and is not the gcloud identity agents use, and no human principal needs `secretAccessor`. The read side has three agent paths that this does not close: (1) the owner's daily gcloud ADC, if it is project Owner; (2) the `pass-cli` session, which holds every value; (3) on Talos, the service account signing key in the cluster Terraform state, which mints tokens that Google STS accepts from anywhere. See [Agent read paths](#agent-read-paths). B rates above A only once (2) and (3) are closed. |
| Write cost, N clusters | **Lowest for values, moderate for IAM.** One version write; every cluster picks it up within its `refreshInterval`. IAM upkeep: O(secrets x namespaces x pools) bindings with per-secret grants, each new tenant secret an `infra` change and a person-run apply; O(namespaces) with prefix-conditioned grants. A new cluster needs a pool, a provider and bindings, no value work. |
| kind | Poor fit. A kind cluster gets new service account signing keys at each creation **(unverified for kind; kubeadm generates them at init)**, so each create needs a JWKS upload, a network, and a GCP write by the person. The plan already gives kind an in-cluster store with dummy values; see option B-kind below. |
| Bootstrap credential | **None on GKE.** None on Talos either: ESO uses projected service account tokens; the credential configuration is not secret. Terraform must upload the JWKS (public). |
| Outage | Secret Manager or internet down: running pods keep their Secrets (in etcd); refreshes fail and `Ready` goes `False`; new namespaces and a rebuild during the outage cannot get values. A Pi cluster at home loses refresh during an ISP outage. |
| DR / key loss | No key to lose: Google-managed encryption. Cluster loss: rebuild and re-bind IAM; values are untouched. Account or billing suspension, or project deletion: values gone from the backend; Proton Pass re-seeds them with one task run. |
| Cost | See [Cost](#cost-of-gcp-secret-manager). About USD 2 to 3 per month at the expected size. |
| Talos | Works through `workloadIdentityFederation`. The service account signing key is in `talos_machine_secrets.machine_secrets.certs.k8s_serviceaccount`, so it is in the Terraform state of the cluster (R2) ([provider docs](https://raw.githubusercontent.com/siderolabs/terraform-provider-talos/main/docs/resources/machine_secrets.md), **verified**). Whoever reads that state can sign tokens for any namespace and read every secret granted in that pool, without touching the cluster. Rotating it requires a JWKS re-upload and is disruptive. See [Talos specifics](#talos-specifics). |
| GKE | **Native.** No extra component, no Google service account needed. |
| Complexity | Low: a GCP project, one workload identity pool, one provider per non-GKE cluster, IAM per secret. No stateful service to run. |

Caveat on `property`: homelab's `ExternalSecret` objects set `property: value` because a seed holds a map. In Secret Manager a plain-text payload has no property. The `remoteRef` convention must be fixed per backend before tenants copy it. The fake provider ignores `property` **(verified)**, so a convention of "plain payload, no `property`" should work on both B and B-kind. That `gcpsm` returns the whole payload when `property` is omitted is **(unverified)**: neither the [ESO GCP provider page](https://external-secrets.io/latest/provider/google-secrets-manager/) nor the [ExternalSecret API page](https://external-secrets.io/latest/api/externalsecret/) documents `property` for `gcpsm`. Test it before fixing the convention.

### B-kind. ESO fake provider for kind

Not a full backend, but it answers the kind row of every option. The store `secrets` on kind uses `provider.fake.data` with obviously dummy values, rendered from the cluster overrides of `gitops/clusters/<kind-cluster>/cluster.yaml`. It works offline, needs no person, no seed namespace and no Terraform root. The values are public by design. The secret scanners must not flag them (use values like `dummy-not-a-secret`).

Cross-repo coupling: the fake store returns only the keys it lists. A tenant `ExternalSecret` in `gsuquet/gitops` that references a key the kind store does not list stays `NotReady` on kind. Proposed convention: the tenant onboarding file `gitops/tenants/<tenant>.yaml` in `infra` lists the secret keys of each tenant namespace (names only), and the render generates one dummy entry per key in the kind store of that namespace. The same list can drive the prefix-conditioned IAM bindings of option B, so one list feeds both. A tenant adding a secret then needs an `infra` change, which keeps the platform in control of what a tenant can read.

The Kubernetes provider with seeds (option A without SOPS) also works on kind, but needs a Terraform step or a manifest per seed and a beta provider for no gain.

### C. Sealed Secrets

A controller per cluster holds a private key; `kubeseal` encrypts against the public certificate of one cluster; the `SealedSecret` is committed and the controller decrypts it in the cluster. Facts in this section are **(unverified)**: the project documentation is outside the allowed domains.

| Criterion | Assessment |
| --- | --- |
| Public repo | Ciphertext in Git, per cluster. A leaked controller key opens every past `SealedSecret` of that cluster. |
| Agent isolation | `kubeseal` needs only the public certificate, so an agent can seal a value it is given; the risk is the person piping plaintext through an agent session. Decryption is in-cluster only. |
| Write cost, N clusters | **High.** One seal and one commit per cluster per value. Rotation is N seals. |
| kind | Each new kind cluster has a new key, so committed `SealedSecret` objects do not decrypt, unless a fixed key is injected, which is then a secret on the laptop. |
| Bootstrap credential | The controller key, generated in cluster, or injected for DR. |
| Outage | None at run time. |
| DR / key loss | The controller key must be backed up per cluster, or every `SealedSecret` of that cluster is unreadable after a rebuild. Values can be re-sealed from Proton Pass. Key renewal (every 30 days by default) adds keys; old keys must be kept to read old objects. |
| Cost | Free. |
| Talos / GKE | Works the same everywhere; ignores Secret Manager on GKE. |
| Complexity | Medium. Does not use ESO, so it breaks the "one store named `secrets`" contract of the plan. |

Assessment: rejected. It scales per cluster, ties ciphertext to cluster keys, and bypasses ESO.

### D. SOPS decrypted in the cluster (KSOPS, sops-secrets-operator)

KSOPS is a Kustomize plugin run by the Argo CD repository server; a SOPS operator decrypts a `SopsSecret` custom resource in the cluster. Both put an age (or KMS) key in every cluster. Tool facts are **(unverified)** (outside the allowed domains, except SOPS itself on `github.com/getsops`).

| Criterion | Assessment |
| --- | --- |
| Public repo | Ciphertext in Git, as in A. |
| Agent isolation | As A. |
| Write cost, N clusters | One edit if all clusters are recipients of one file, but then the same file opens on every cluster; per-cluster files cost N edits. No apply step. |
| kind | Needs an age key in each kind cluster: a key on the laptop, re-injected at each create. |
| Bootstrap credential | **An age key per cluster**, injected by Terraform (in state) or by hand. |
| Outage | None at run time. |
| DR / key loss | Same as A, plus a key copy in every cluster etcd. |
| Cost | Free (age). |
| Talos / GKE | Works; GKE could use Cloud KMS as the SOPS key instead of age. |
| Complexity | KSOPS conflicts with the rendered manifests pattern: Argo CD must run Kustomize with a plugin instead of applying plain YAML, or the render step must decrypt, which writes plaintext into `rendered/` in Git. A SOPS operator avoids that but bypasses ESO. |

Assessment: rejected. It breaks either the rendered manifests pattern or the ESO contract, and it puts a decryption key in every cluster.

### E. Self-hosted OpenBao (or Vault)

ESO reads through the Vault provider (`stable`), which ESO documents for OpenBao (`alpha` pairing, **verified**). Each cluster authenticates with the Kubernetes or JWT auth method. Operational facts below are **(unverified)**: `openbao.org` is outside the allowed domains.

| Criterion | Assessment |
| --- | --- |
| Public repo | Nothing in Git. |
| Agent isolation | Good: policies per path, a writer token that agents do not hold. |
| Write cost, N clusters | One write. |
| kind | Needs network access from kind to the server and an auth role per kind cluster, or the fake provider. |
| Bootstrap credential | Kubernetes auth: OpenBao must reach each cluster API server for TokenReview. JWT auth: the JWKS of each cluster, the same upload problem as B. |
| Outage | Self-inflicted: if OpenBao runs on the Pi cluster, a Pi outage stops every cluster's refresh, and the Pi cluster cannot bootstrap itself (circular dependency). If it runs elsewhere, that host is a new single point of failure. |
| DR / key loss | Unseal keys or an auto-unseal KMS (back to a cloud KMS), Raft snapshots to back up off-site, and a tested restore. Losing the unseal keys and the snapshots loses everything. |
| Cost | No license; the cost is hardware, an always-on host, and time. |
| Talos | Works; same JWKS rotation concern with JWT auth. |
| GKE | Possible, but pointless next to Secret Manager. |
| Complexity | **Highest**: a stateful HA service (3 nodes for Raft), upgrades, unseal, backups, audit logs, TLS. Its real advantages (dynamic database credentials, PKI, leases) are not requirements today. |

Assessment: not now. Reconsider if dynamic credentials or an internal PKI become requirements.

### F. Other ESO providers (SaaS)

Bitwarden Secrets Manager, 1Password, Infisical, Doppler, Keeper and Passbolt all have `alpha` ESO providers **(verified)**. Each needs a machine token per cluster (secret zero, a static credential stored in the cluster), a new vendor, and a network. None works offline. 1Password needs Connect or an SDK service account; Bitwarden needs the `bitwarden-sdk-server` **(unverified)**.

Proton Pass has **no ESO provider** **(verified absent)**. The Generic Webhook provider (`alpha`) could call an HTTP API, but no documented Proton Pass machine API was found in the allowed domains **(unverified)**, and it would put a Proton credential with vault access in every cluster. So Proton Pass fits as the human source of truth that feeds the backend, not as the backend.

Assessment: rejected. `alpha` providers, a static token per cluster, and none removes a step compared to B.

### G. Hybrid: B for real clusters, B-kind for kind, Proton Pass as source

This is B plus B-kind, with the write path from Proton Pass. It is the recommendation. It inherits the rows of B for Talos and GKE and the rows of B-kind for kind.

## Agent read paths

Agents run as the owner's OS user. A value is only as isolated as the weakest credential that user can reach. For B and G:

| Path | Reach | Control that closes it |
| --- | --- | --- |
| Daily gcloud ADC with Owner (or any role with `secretmanager.versions.access`) on the secrets project | Every secret | Daily identity holds no Secret Manager role on that project; the writer identity holds `secretVersionAdder` only and needs an explicit step (separate account or impersonation). |
| `pass-cli` session of the owner | Every value of every cluster (Proton Pass is the source of truth and the DR copy) | A dedicated Proton Pass vault for cluster values, opened by a separate login; re-authentication or biometric per use; a short session lifetime. Without these, `pass-cli` is an agent read path whatever the backend. **(unverified: which of these `pass-cli` supports; this study did not run it)** |
| Talos cluster Terraform state (R2): service account signing key and admin kubeconfig | With the signing key, any namespace principal of the pool, from anywhere, through Google STS and the uploaded JWKS. With a shared pool, every Talos cluster of the pool. | One workload identity pool per Talos cluster (limits the blast radius to one cluster). Keep agents away from the state of production Talos roots: a state credential agents do not hold, `cluster:up`/`plan` for production run by a person only, or a signing key generated outside Terraform and injected without a state copy. |
| kubeconfig that reads Secrets | Values of that cluster, from a network that reaches its API server | Same for every option. |

Option A has the same `pass-cli` path (values come from Proton Pass there too), and on Talos the same state holds the admin kubeconfig. The difference is reach: with A, a leaked Talos state reads values only from a network that reaches the API server; with B, the signing key works from anywhere through STS. So A and B rate the same on agent isolation until the `pass-cli` and Talos state paths are closed, and B rates higher only after that.

## Talos specifics

- The service account signing key comes from `talos_machine_secrets` (`certs.k8s_serviceaccount`) and is stored, with every other cluster secret, in the Terraform state of the cluster root (R2) **(verified, provider schema)**. That state is already sensitive regardless of the secrets backend, but option B turns the signing key into an off-cluster credential for Secret Manager (see [Agent read paths](#agent-read-paths)). The machine config field is `cluster.serviceAccount`, a single `PEMEncodedKey`, "the base64 encoded private key for service account token generation" ([Talos v1.12 config reference](https://docs.siderolabs.com/talos/v1.12/reference/configuration/v1alpha1/config), **verified**; same in [v1.11](https://docs.siderolabs.com/talos/v1.11/reference/configuration/v1alpha1/config)). The Talos study targets Talos 1.14; the v1.14 reference page did not show the field when fetched, so the 1.14 shape is **(unverified)**. Update these links when the Talos pin is set.
- `talosctl rotate-ca` rotates the Talos API CA and the Kubernetes API CA only. The [CA rotation page](https://docs.siderolabs.com/talos/v1.11/security/ca-rotation) says "Other Kubernetes secrets might need to be rotated manually as required" **(verified)**. Whether that covers the service account key is not stated **(unverified)**; assume a manual machine config change.
- The JWKS changes only when that key changes. A `cluster:up` post-step can read `/openid/v1/jwks` and commit it as public data for `landing-zone/gcp` to set `jwks_json` (see [Terraform ownership](#b-gcp-secret-manager-single-store-for-all-clusters-eso-gcpsm)).
- **Rotation is disruptive, all at once.** Because the Talos config carries one service account key, the API server most likely verifies only tokens signed by the current key after the switch, so every projected token in the cluster (every pod, not only ESO) becomes invalid until kubelet refreshes it, and long-lived token Secrets stop working. A two-key overlap would need extra API server flags and files outside `cluster.serviceAccount` **(unverified on Talos)**. Plan a rotation as a maintenance event: change the key, apply, re-read and re-upload the JWKS, apply `landing-zone/gcp`, and restart workloads that cache tokens. Uploading old and new keys to the JWKS during the switch is harmless and avoids STS failures for tokens issued just before it.
- The issuer need not be public (`--jwk-json-path` / `jwks_json`). It must match the `iss` claim of the tokens exactly. The Talos default issuer is the cluster endpoint **(unverified)**.
- Talos generates encryption-at-rest secrets for etcd (`secretbox_encryption_secret`, `aescbc_encryption_secret` in `talos_machine_secrets`, **verified**). Encryption at rest being on by default is **(unverified)**.

## GKE specifics

- Workload Identity Federation for GKE gives each namespace/KSA pair a principal without a Google service account **(verified)**.
- All GKE clusters in one project share the pool `PROJECT_ID.svc.id.goog`, so namespace `foo` / KSA `bar` is the same principal on every GKE cluster of that project **(verified, by the principal format)**. If two GKE clusters must not share a secret, put them in different projects or use per-cluster secret names and accept that IAM cannot tell them apart.
- On Standard clusters, pods need nodes with the GKE metadata server enabled; Autopilot handles it **(verified)**.
- The same applies to Talos clusters that share a pool: the `principal://` identifier names the pool and the subject, not the provider **(verified, by the principal format)**. With `google.subject=assertion.sub` alone, `system:serviceaccount:foo:bar` is the same principal on every Talos cluster of the pool. Default: **one pool per Talos cluster**. In a shared pool with `google.subject=assertion.sub`, a leaked signing key of one cluster mints principals that every Talos cluster of the pool shares, so it reads the secrets of all of them. A subject mapping that prefixes the cluster name (a constant per provider) avoids that, but one wrong mapping re-opens it silently. Separate pools limit a leaked key to one cluster by construction **(design note)**.

## Cost of GCP Secret Manager

From the [pricing page](https://cloud.google.com/secret-manager/pricing), read on 2026-11-18 **(unverified)**: the page is rendered by JavaScript and a plain fetch returns only its title, so these numbers could not be reproduced by a second reader. Check them in a browser before relying on them.

| Item | Free tier (per month, per account) | Price above the free tier |
| --- | --- | --- |
| Active secret versions | 6 | USD 0.06 per version per month |
| Destroyed secret versions | all | free |
| Access operations | 10,000 | USD 0.03 per 10,000 |
| Management operations | all | free |
| Rotation notifications | 3 | USD 0.05 each |

Whether a version replicated to several locations counts once or once per location is **(unverified)**: the page example does not show it. Whether "account" means billing account is **(unverified)**.

Estimate for 40 secrets with user-managed replication in a single location, one enabled version each (older versions destroyed), 3 non-kind clusters, every value read by every cluster, `refreshInterval: 1h`. If versions are billed per replica location, automatic or multi-location replication multiplies the version cost by the number of locations:

- Versions: (40 - 6) x 0.06 = USD 2.04 per month.
- Accesses: 40 x 3 x 24 x 30 = 86,400 per month, so (86,400 - 10,000) / 10,000 x 0.03 = about USD 0.23 per month. One access per refresh per `ExternalSecret` is an assumption **(unverified)**.
- Total: about **USD 2.3 per month**. A 24h refresh removes almost all the access cost.

Disabled (not destroyed) versions likely still count as active **(unverified)**; destroy old versions after a rotation.

## Comparison table

Legend: ++ best, + good, 0 neutral, - poor, -- blocking. The `pass-cli` read path applies to every option whose values come from Proton Pass, so the agent isolation row scores the other paths; no option is better than `0` there until the `pass-cli` session is protected.

| Criterion | A. SOPS + seeds | B. GCP SM | B-kind. fake | C. Sealed | D. SOPS in cluster | E. OpenBao | F. SaaS |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Public repo (nothing to harvest) | - | ++ | 0 (dummies) | - | - | ++ | ++ |
| Agent isolation (no agent read path, `pass-cli` path aside) | 0 | 0 on Talos (+ once agents cannot read Talos state), + on GKE | n/a | 0 | 0 | + | + |
| Write cost for N clusters (values and IAM) | -- | + (++ with prefix-conditioned IAM) | n/a | -- | 0 | ++ | ++ |
| kind, offline and unattended | - | -- | ++ | - | - | -- | -- |
| No bootstrap credential per cluster | + | ++ | ++ | 0 | - | 0 | - |
| Outage resilience | ++ | 0 | ++ | ++ | ++ | - | 0 |
| DR and key loss | 0 | + | ++ | - | - | - | + |
| Cost | ++ | + (about USD 2-3/month) | ++ | ++ | ++ | - | 0 |
| Talos fit | + | 0 (disruptive key rotation, JWKS re-upload, signing key in state) | n/a | + | 0 | 0 | 0 |
| GKE fit | 0 | ++ | n/a | 0 | 0 | - | 0 |
| Operational complexity | - | + | ++ | 0 | - | -- | 0 |
| Keeps ESO store `secrets` contract | yes | yes | yes | no | KSOPS no / operator no | yes | yes |
| Fits rendered manifests | yes | yes | yes | yes | KSOPS no | yes | yes |

## Recommendation

Option G:

1. **GCP Secret Manager is the single backend for every non-kind cluster** (Talos and GKE), through ESO `gcpsm` and the per-namespace store `secrets`. GKE uses `workloadIdentity`; Talos uses `workloadIdentityFederation` with **one workload identity pool per Talos cluster** and its public JWKS set by `landing-zone/gcp` (`jwks_json`), so the cluster root keeps the settled bootstrap boundary. IAM grants `secretAccessor` once per namespace principal, conditioned on a secret name prefix.
2. **kind uses the ESO fake provider** with dummy values under the same store name, one entry per secret key listed in the tenant or component definition. No credential, no network, no person.
3. **Proton Pass stays the only human store.** A person-run task (`pass-cli run`, never run by agents) writes versions to Secret Manager with a write-only argument or a pipe, through an identity that holds only `secretVersionAdder` and that agents do not use. Cluster values live in a dedicated Proton Pass vault behind a separate login with re-authentication per use, so the agent's OS user has no open session on them.
4. **Agents cannot read production Talos state.** The R2 state of production Talos roots holds the service account signing key; its credential is not reachable by agents, and `cluster:up`/`plan` for those roots is person-run. Until this holds, option B is no better than A on agent isolation.
5. **The platform owns the stores.** Tenants cannot create `SecretStore`, `ClusterSecretStore` or `PushSecret`; see ADR 0020 Confirmation.
6. **No ciphertext in Git.** No SOPS file, no `SealedSecret`. The age and SOPS tooling of homelab is not carried over.

Why: one value write per change whatever N is, and O(namespaces) IAM bindings; no secret zero on any cluster; nothing harvestable in the public repos; the store contract and the rendered manifests pattern stay intact; the cost is a few dollars a month (pricing unverified); and Proton Pass covers DR of the values. The price is a cloud dependency for Pi clusters at refresh time, a disruptive service account key rotation on Talos, and two access controls (Proton Pass session, Talos state) that must exist for the isolation argument to hold.

Fallback if the owner rejects any cloud dependency for the Pi clusters: option A for Talos only (one SOPS file per cluster), with B-kind on kind and B on GKE. The ESO store contract makes that a per-cluster choice.

## Open questions for the owner

1. Is a GCP dependency acceptable at refresh time for the Pi clusters (home ISP outage = no refresh, no rebuild)?
2. One GCP project for secrets of all clusters, or one per environment (prod / non-prod)? This also decides whether GKE clusters share a workload identity pool.
3. Workload identity pools: one per Talos cluster (recommended default), or one shared pool with a cluster attribute in the subject mapping?
4. Secret naming in Secret Manager: per cluster (`<cluster>--<namespace>--<name>`), shared (`<namespace>--<name>`), or both? This decides whether one write updates every cluster.
5. Write path: Terraform write-only (`secret_data_wo`, a version counter in Git, a person-only root) or a `gcloud ... --data-file=-` pipe from `pass-cli` (no state at all)?
6. Which identity writes versions? A separate Google account, or impersonation of a writer service account that the daily gcloud configuration cannot use without an explicit step?
7. `remoteRef` convention: plain-text payloads with no `property` (works with fake and `gcpsm`), or JSON payloads with `property: value` (keeps homelab objects)?
8. `refreshInterval` default: 1h (faster rotation) or 24h (lower cost, less traffic)?
9. Tenants in `gsuquet/gitops`: may a tenant `ExternalSecret` read only secrets prefixed with its tenant name, enforced by prefix-conditioned IAM on its namespace principals? Who writes tenant values? Does the tenant file in `infra` list secret keys (feeding kind dummies and IAM)?
10. Is option A acceptable as the documented fallback for an offline-only cluster, or is it dropped entirely?
11. Talos state isolation: how are agents kept away from the signing key in production Talos state? A separate R2 credential agents do not hold, person-only `cluster:up`/`plan` for production roots, or a signing key generated outside Terraform? Without one of these, option B gives agents an off-cluster read path to Secret Manager.
12. Proton Pass session: a dedicated vault for cluster values with a separate login, re-authentication per use, and a session lifetime? Without it, `pass-cli` is an agent read path for every option.
13. Bootstrap boundary: does the Talos workload identity provider and its JWKS live in `landing-zone/gcp` (fed by a committed public JWKS, recommended), or in the cluster root (which then needs Google credentials and a post-bootstrap API read in every `cluster:up`)?
14. Tenant enforcement in `gsuquet/gitops`: Conftest in that repo's CI, an admission policy in each cluster, or both?
