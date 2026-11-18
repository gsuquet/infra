---
status: proposed
date: 2026-11-18
decision-makers: repository owner
---

# Secrets backend behind the ESO store `secrets`

## Context and Problem Statement

Every namespace of every cluster reads its secret values through an External Secrets Operator (ESO) store named `secrets`, so that the backend can change without touching the `ExternalSecret` objects. The backend itself is open.

The platform runs N clusters: ephemeral kind clusters on dev machines, Talos clusters on Raspberry Pis and local servers, and GKE. `gsuquet/infra` and `gsuquet/gitops` are public. Agents write the code and must never read or write a value. The owner keeps human credentials in Proton Pass and already injects them with `pass-cli run`.

Which backend should the store `secrets` use on each kind of cluster, and how do values get into it?

The full comparison is in [Secrets backend study](../research/secrets-backend.md).

## Decision Drivers

- Nothing harvestable in public Git history, ciphertext included.
- A real control between agents and values: an identity agents do not use.
- The cost of one secret change must not grow with the number of clusters.
- kind must work offline, unattended, and be recreated at will.
- No static bootstrap credential (secret zero) per cluster if avoidable.
- Keep the ESO store contract and the rendered manifests pattern (no decryption in Argo CD or in the render step).
- Low operational load: no new stateful service to run, back up and unseal.
- Recoverable after loss of a key, a cluster, or an account.

## Considered Options

- A. SOPS + age, Terraform-written seed Secrets, ESO Kubernetes provider (the homelab model)
- B. GCP Secret Manager as single store, ESO `gcpsm` provider (Workload Identity on GKE, Workload Identity Federation on Talos)
- C. Sealed Secrets
- D. SOPS decrypted in the cluster (KSOPS or a SOPS operator)
- E. Self-hosted OpenBao or Vault
- F. A SaaS secrets manager with an ESO provider (Bitwarden, 1Password, Infisical, Doppler); Proton Pass has no ESO provider
- G. Hybrid: B on Talos and GKE, ESO fake provider with dummy values on kind, Proton Pass as the human source of truth

## Decision Outcome

Proposed: **G**, because it is the only option that gives one write per change whatever the number of clusters, no ciphertext in Git, and an offline kind, without a new stateful service to run (E) or a static token per cluster (F), while keeping the store contract.

- Talos and GKE: store `secrets` with provider `gcpsm`. GKE uses `auth.workloadIdentity`; Talos uses `auth.workloadIdentityFederation` with one workload identity pool per Talos cluster and the cluster's public JWKS set by `landing-zone/gcp` (`jwks_json`), so the issuer stays private and the cluster root keeps the bootstrap boundary. `roles/secretmanager.secretAccessor` is granted once per namespace principal with an IAM Condition on a secret name prefix.
- kind: store `secrets` with provider `fake` and one dummy value per secret key listed in the tenant or component definition in `infra`.
- Values: a person-run task resolves Proton Pass references with `pass-cli run` and writes Secret Manager versions through a write-only path, with an identity that holds only `roles/secretmanager.secretVersionAdder` and that agents do not use.
- Agent isolation rests on two controls that must exist before G is better than A: cluster values in a Proton Pass vault behind a separate login with re-authentication per use, and production Talos Terraform state out of agents' reach.

The decision is left to the owner; the open questions below must be answered first.

### Consequences

- Good: one version write updates every cluster that reads the secret within its `refreshInterval`.
- Good: no SOPS file, no age key, no `SealedSecret`, no seed namespace, no per-cluster secrets root module.
- Good: the public repositories hold only names, IAM bindings and public JWKS.
- Good: GKE needs nothing beyond Workload Identity Federation for GKE.
- Good: Proton Pass is the DR copy of every value; a lost GCP project is re-seeded by one task run.
- Bad: Pi clusters depend on the internet and on GCP to refresh or to rebuild; running pods keep their Secrets.
- Bad: the Talos service account signing key in the cluster Terraform state (R2) becomes an off-cluster credential: with it, anyone can mint tokens for any namespace of that cluster, exchange them at Google STS through the uploaded JWKS, and read every secret granted to those principals, from anywhere. Agents run as the owner's OS user, so this is an agent read path unless production Talos state is out of their reach. One pool per Talos cluster limits it to one cluster.
- Bad: Talos carries a single service account key, so a key rotation is a disruptive, all-at-once event for every in-cluster token, plus a JWKS re-upload.
- Bad: the `pass-cli` session of the owner can read every value; as for every option sourced from Proton Pass, the session needs its own protection (dedicated vault, separate login, re-authentication).
- Bad: a billed GCP project, about USD 2 to 3 per month at 40 secrets and 3 clusters with single-location replication (pricing read in a browser, not reproducible by fetch: unverified).
- Bad: tenant secrets need a name-prefix convention and a key list in `infra` (for IAM conditions and kind dummies), which couples `gsuquet/gitops` to `infra`.
- Bad: the homelab `ExternalSecret` convention `property: value` does not carry over as is; the `remoteRef` convention must be fixed.
- Neutral: anyone with a kubeconfig that can read Secrets in a cluster still reads values there; this is the same for every option.

### Confirmation

- Conftest on `infra` refuses any `ClusterSecretStore`, any `SecretStore` not named `secrets`, any `fake` provider outside kind clusters, and any `secretRef` (static key) auth for `gcpsm`.
- The tenant `AppProject` adds `SecretStore` and `PushSecret` (group `external-secrets.io`) to `namespaceResourceBlacklist`, next to `NetworkPolicy` and `CiliumNetworkPolicy`, so only the platform creates the store `secrets` in a tenant namespace. `ClusterSecretStore` and `ClusterExternalSecret` are cluster-scoped and already refused to tenants.
- Tenant manifests in `gsuquet/gitops` are outside `infra` CI. Tenant-side enforcement needs Conftest in `gsuquet/gitops` CI, an admission policy in each cluster, or both. This is a requirement for the tenant onboarding work.
- A test cluster on kind shows every `ExternalSecret` `Ready` with no network.
- A first Talos cluster shows `Ready` stores through Workload Identity Federation with a private issuer.
- `git grep` and the secret scanners find no ciphertext and no value in either public repository.

## Pros and Cons of the Options

### A. SOPS + age, seed Secrets, ESO Kubernetes provider

- Good: works offline, free, no cloud dependency, proven in homelab.
- Bad: one SOPS edit and one person-run apply per cluster per change.
- Bad: ciphertext in public Git forever; a key leak forces a rotation of every value.
- Bad: a second human store next to Proton Pass; high complexity (seed namespaces, state test, clean-environment apply script).

### B. GCP Secret Manager (alone, kind included)

- Good: as G for Talos and GKE.
- Bad: kind would need a JWKS upload, a network and a person at each create.

### C. Sealed Secrets

- Good: free, no runtime dependency.
- Bad: one seal per cluster per change; per-cluster keys to back up; kind gets a new key each time; bypasses ESO.

### D. SOPS decrypted in the cluster

- Good: one edit can serve many clusters.
- Bad: a decryption key in every cluster; KSOPS breaks the rendered manifests pattern (Argo CD must run a plugin, or the render writes plaintext); an operator bypasses ESO.

### E. Self-hosted OpenBao or Vault

- Good: nothing in Git, fine-grained policies, dynamic credentials if needed later.
- Bad: a stateful HA service with unseal, backups and upgrades; on the Pi cluster it is a circular dependency and a single point of failure; ESO marks the OpenBao pairing `alpha`.

### F. SaaS secrets managers

- Good: nothing in Git, one write per change.
- Bad: `alpha` ESO providers, a static machine token per cluster, a new vendor; Proton Pass, the store already in use, has no ESO provider.

### G. Hybrid (proposed)

- Good: see Consequences.
- Bad: two store providers to template (`gcpsm`, `fake`); a GCP dependency for the Pi clusters.

## More Information

Open questions for the owner, to answer before this ADR moves to `accepted`:

1. Is a GCP dependency at refresh time acceptable for the Pi clusters? If not, which fallback (option A on Talos only)?
2. One GCP project for all secrets, or one per environment? This also decides whether GKE clusters share a workload identity pool, and so share principals.
3. One workload identity pool per Talos cluster (proposed), or a shared pool with the cluster name in the subject mapping?
4. Secret naming: per cluster, shared, or both?
5. Write path: Terraform `secret_data_wo` with a version counter in Git, or a `gcloud secrets versions add --data-file=-` pipe from `pass-cli`?
6. Writer identity: a separate Google account, or impersonation of a writer service account?
7. `remoteRef` convention: plain payload without `property`, or JSON payload with `property: value`?
8. Default `refreshInterval`: 1h or 24h?
9. Tenant scope: may a tenant read only secrets prefixed with its name, and who writes tenant values?
10. Talos state isolation: a separate R2 credential agents do not hold, person-only `cluster:up`/`plan` for production Talos roots, or a signing key generated outside Terraform?
11. Proton Pass session: dedicated vault for cluster values, separate login, re-authentication per use, session lifetime?
12. Bootstrap boundary: Talos workload identity provider and JWKS in `landing-zone/gcp` (proposed) or in the cluster root?
13. Tenant enforcement in `gsuquet/gitops`: Conftest in its CI, an admission policy per cluster, or both?

Sources and verification status are listed in [Secrets backend study](../research/secrets-backend.md).
