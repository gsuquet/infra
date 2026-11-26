# Kargo tenants, credentials and checks

Detail of [RFC 0021](../rfc/0021-tenant-promotion-with-kargo.md). Study date 2026-11-18, against Kargo source tag `v1.12.6`.
"Verified" means checked against the linked source; "unverified" means prior knowledge, inference, or
unreachable source. The source links are in [sources](0021-tenant-promotion-with-kargo-evidence.md#sources).

## Multi-tenancy

| Item | Rule |
| --- | --- |
| Project | One per onboarded tenant, named `kargo-<tenant>` to stay clear of tenant workload namespaces on the same cluster (naming is a proposal), on the Kargo host whatever cluster the tenant runs on |
| Pipeline ownership | The Kargo host render joins across every `gitops/clusters/*/cluster.yaml` (ADR-0009). For each tenant listed by at least one cluster it emits the Project namespace, `Project`, `ProjectConfig`, `Warehouse`, one `Stage` per cluster that lists it, plus the shared `ClusterPromotionTask`, into `gitops/clusters/<kargo-host>/rendered/`, applied under the platform AppProject, not the tenant one |
| Project namespace | Rendered by `infra` with `kargo.akuity.io/project: "true"` (Kargo adopts it, verified) and the policy label, so Conftest checks it. A namespace Kargo creates at runtime would lack the label |
| Promotion order | New tenant file field, for example `promotion: [kind, pi, gke]` (extends ADR-0009, needs its own follow-up). Stage N takes Freight from N-1 (`sources.stages`), the first from the Warehouse (`sources.direct: true`). Render fails when the list differs from the clusters that list the tenant |
| Roles | Built-in `kargo-admin`, `kargo-promoter` (promote, approve Freight), `kargo-viewer`, each a ServiceAccount, Role and RoleBinding; custom `promote` verb on `stages`. OIDC claims map with `rbac.kargo.akuity.io/claims`; system roles `kargo-admin`, `kargo-viewer`, `kargo-user`, `kargo-project-creator` through `api.oidc.*` (verified) |
| Tenant access | `kargo-promoter` and `kargo-viewer` on its own Project, never `kargo-admin` (admin could repoint its Stage at another path). Future-proofing: the owner is the only user today |
| Auto-promotion | `ProjectConfig.spec.promotionPolicies` (`stageSelector`, `autoPromotionEnabled`) (verified). It only opens pull requests automatically. Default: on for `kind`, off for later clusters |
| Soak | `requestedFreight[].sources.requiredSoakTime` (verified): the only time gate between clusters without verification |

## Credentials

| Need | Credential | Scope |
| --- | --- | --- |
| Clone, push branches, open and read pull requests on `gsuquet/gitops` | Dedicated GitHub App installation token | `gsuquet/gitops` only |
| Read public images and OCI charts on `ghcr.io` | None (anonymous OCI pulls through Kargo: unverified) | - |
| Read public app repositories (`git` subscription) | None | - |
| Kargo admin account | `api.adminAccount.passwordHash`, `tokenSigningKey` | kind only |
| UI login on a long-lived cluster | OIDC through Dex and a GitHub OAuth App, or an OIDC provider with PKCE | owner only |

| GitHub App fact | Status |
| --- | --- |
| Secret labelled `kargo.akuity.io/cred-type: git` with `githubAppClientID` (preferred over deprecated `githubAppID`), `githubAppPrivateKey`, `githubAppInstallationID`, `repoURL`; the CLI cannot create it | verified |
| Delivered by an `ExternalSecret` on store `secrets` (ADR-0016), label set through the ESO target template | proposal |
| App-authored pull requests let the owner approve under "one approval required"; with a personal token the owner is the author and cannot approve their own pull request | unverified (standard GitHub behaviour) |
| Installation tokens are short-lived and "not tied to a specific GitHub user" | verified; one-hour lifetime unverified |
| Permissions: Contents read and write | verified |
| Permissions: Pull requests read and write, Metadata read | unverified (inferred from the GitHub API) |
| Installed on `gsuquet/gitops` only: an App gets its permissions on every repository it is installed on | verified |
| In the namespace named under [Security](../rfc/0021-tenant-promotion-with-kargo.md#operational-impact): usable by every Project, unreadable by Project users (`secret()` cannot reference shared credentials) | verified |
| `kargo.akuity.io/github-token-scopes` (experimental, since `v1.8.0`) limits repositories per Project, not paths; adds nothing with one repository | verified |
| Lookup: Project namespace first, shared namespace only when nothing matches; exact `repoURL` beats regex, then Secret name order. A Secret created in a Project namespace overrides the platform credential | verified |

Rules from the lookup order:

- Tenants get no `create` or `update` on `Secret`s in their Project namespace. `kargo-viewer` does
  not reach credentials and `kargo-promoter` cannot edit pipeline resources (verified); the exact
  Secret verbs of built-in roles are undocumented (unverified): check with
  `kargo get role <name> --as-kubernetes-resources` in slice 1.
- `infra` renders no Secret or `ExternalSecret` labelled `kargo.akuity.io/cred-type` into Project
  namespaces; the gate is in [Confirmation checks](#confirmation-checks).
- The path boundary of the App is the pull request check
  below plus the human review.

## Pull request checks on `gsuquet/gitops`

Tenant charts render inside the Kargo controller, outside `infra`'s `manifests:check`, kubeconform
and Conftest. Without a check, bad or malicious output is stopped only by the human review and, at
sync time, by the tenant AppProject (ADR-0009). A required status check on `main` of
`gsuquet/gitops` (proposal):

| Check | Rule |
| --- | --- |
| Path scope | Every changed path under one `tenants/<tenant>/<cluster>/`, `<tenant>` matching the `tenant/<tenant>` label, `<cluster>` a cluster the tenant is onboarded on; a `kargo/promotion/*` branch touching anything else fails |
| kubeconform | Changed directory, with the CRD schemas the platform ships (ESO, Gateway API) |
| Conftest | Tenant rules shared with `infra` (ADR-0009, ADR-0010, ADR-0016): no cluster-scoped kind, no `Namespace`, no `NetworkPolicy` or `CiliumNetworkPolicy`, no `Secret` with `data` or `stringData`, no `SecretStore` or `ClusterSecretStore`, every `ExternalSecret` on `SecretStore` `secrets` |
| CODEOWNERS | Per `tenants/<tenant>/` once there is more than one human (open question [Branch protection](../rfc/0021-tenant-promotion-with-kargo.md#open-questions)) |

Policies live once, in `infra`'s `policy/`, pulled by the `gsuquet/gitops` workflow at a pinned
commit, so the two cannot drift. The workflow is outside this repository's CI scope (ADR-0019).
Branch protection: see [Confirmation checks](#confirmation-checks).

## Confirmation checks

- Conftest or a render check fails when any rendered `Stage`, `PromotionTask` or
  `ClusterPromotionTask` uses `argocd-update`, `argocd-wait` or `git-merge-pr`.
- At most one `cluster.yaml` enables `kargo`; no shared kind settings enable it.
- A render check fails unless every (tenant, cluster) pair listed by any `cluster.yaml` has exactly
  one `Stage` on the Kargo host, and each tenant's `promotion` list equals the clusters that list it.
- Conftest fails any object labelled `kargo.akuity.io/cred-type` outside `kargo-shared-resources`.
- Every Kargo Project namespace is rendered by `infra` and carries the policy label.
- `gsuquet/gitops` `main` requires the path-scope, kubeconform and Conftest check, a pull request
  with one approval, repository auto-merge disabled, the App in no bypass list, head branches auto-deleted.
- Footprint peaks recorded in `gitops/components/kargo/README.md` before requests, limits and a Pi
  host are fixed.
