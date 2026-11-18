# Kargo study: tenant promotion

Status: input for [ADR 0021](../adr/0021-tenant-promotion-with-kargo.md). Research date: 2026-11-18.

This study checks whether Kargo fits the tenant promotion model of the platform plan: application code in its own repositories, rendered tenant manifests in the public repository `gsuquet/gitops` under `tenants/<tenant>/<cluster>/`, one self-managed Argo CD per cluster, no hub, and git-only promotion steps that end in a pull request that a human merges.

Facts marked **(verified)** were checked on the date above against the source linked next to them, or against the Kargo source tree at tag [`v1.12.6`](https://github.com/akuity/kargo/tree/v1.12.6). Facts marked **(unverified)** come from prior knowledge, from an inference, or from a source that was not reachable. Check them before you build on them.

## Versions cited

| Item | Version | Source |
| --- | --- | --- |
| Kargo (latest release) | `v1.12.6`, published 2026-11-16 | [GitHub releases](https://github.com/akuity/kargo/releases) **(verified)** |
| Kargo Helm chart | `oci://ghcr.io/akuity/kargo-charts/kargo`, version `1.12.6` | [Basic installation](https://docs.kargo.io/operator-guide/basic-installation) gives the OCI reference and `1.12.x` **(verified)**; the chart version equal to the release tag is set by the release process ([`Chart.yaml`](https://github.com/akuity/kargo/blob/v1.12.6/charts/kargo/Chart.yaml)); the published `1.12.6` chart artifact on `ghcr.io` was not pulled **(unverified)** |
| Kargo API group | `kargo.akuity.io/v1alpha1` | [`api/v1alpha1`](https://github.com/akuity/kargo/tree/v1.12.6/api/v1alpha1) **(verified)** |
| Next Kargo release | `v2.0.0` (there is no `v1.13.0`) | [Roadmap](https://docs.kargo.io/roadmap) **(verified)** |
| Argo Rollouts (only for verification) | chart `argo-rollouts-2.43.12`, app `v1.10.2` | [argo-helm](https://github.com/argoproj/argo-helm) `Chart.yaml` at that tag **(verified)** |
| Argo CD (for the Source Hydrator alternative) | `v3.6.2` | [GitHub releases](https://github.com/argoproj/argo-cd/releases) **(verified)** |
| License | Apache-2.0 | GitHub repository metadata of `akuity/kargo` **(verified)** |

The Kargo quickstart script at `v1.12.6` installs cert-manager chart `1.19.3`, Argo CD chart `9.4.3` and Argo Rollouts chart `2.40.6` next to Kargo ([`hack/quickstart/kind.sh`](https://github.com/akuity/kargo/blob/v1.12.6/hack/quickstart/kind.sh)) **(verified)**. These are the versions the maintainers test the quickstart with, not hard requirements.

## Summary

- Kargo runs without Argo CD. Every step that this plan needs is a built-in, open-source step: `git-clone`, `oci-download`, `untar`, `delete`, `helm-template` (or `kustomize-build`), `git-commit`, `git-push`, `git-open-pr`, `git-wait-for-pr` **(verified)**.
- The cost of dropping `argocd-update` is real: with no health check registered, a Stage is `Healthy` as soon as the Promotion succeeds, and with git-only steps the Promotion succeeds when the pull request is merged, not when the workload runs. Kargo then knows that the change is in Git, not that it is deployed **(verified in source)**.
- Verification (`AnalysisTemplate`) can replace part of that signal, but it needs the Argo Rollouts controller, and with no health gate it starts right after the merge, before Argo CD syncs. A verification must poll until the new version answers. Without verification, the human merge is the only gate.
- Kargo has no hub requirement. A standalone install on one cluster can promote to every cluster, because every promotion only writes to `gsuquet/gitops`. Kargo needs no network path and no credentials to the target clusters.
- The API is still `v1alpha1`, and the next release is a `v2.0.0` that replaces the storage and change-detection layer. That is the main maturity risk.

## Architecture

From the [architecture page](https://docs.kargo.io/operator-guide/architecture) **(verified)**:

| Component | Runs in | Required | Internet-facing | Role |
| --- | --- | --- | --- | --- |
| API server | control plane | yes | yes (UI and CLI) | Backend for UI and CLI; serves the UI. |
| Controller | control plane, or one per shard in other clusters | yes | no | Watches repositories (Warehouses), runs Promotions, runs health checks, creates `AnalysisRun`s. |
| Management controller | control plane | yes | no | Grants and revokes per-Project RBAC as Projects come and go. Holds broad permissions, so it is never distributed. |
| Kubernetes webhooks server | control plane | yes | no | Validating and mutating admission webhooks. Needs TLS; the chart uses a cert-manager self-signed `Issuer` by default. |
| External webhooks server | control plane | no | yes | Receives push notifications (for example from GitHub) to refresh Warehouses early. |
| Garbage collector | control plane | enabled by default | no | Hourly CronJob that deletes old terminal Promotions and unused Freight. |
| Dex | control plane | no | yes (through the API server) | OIDC adapter for identity providers without OIDC, for example GitHub. |

All Kargo state is stored as custom resources in the control plane cluster. There is no database.

### Topologies and sharding

- **Standalone**: every component, with one controller, in one cluster. The docs call it suitable for testing and "very small deployments" **(verified)**. This platform is a very small deployment.
- **Distributed (sharded)**: the control plane holds the data; extra controllers run in other clusters, each owning a shard of Stages, and connect back to the control plane with a ServiceAccount token. A shard "typically corresponds to one Argo CD control plane", and a controller works with at most one Argo CD control plane **(verified)**. The chart exposes `kubeconfigSecrets.kargo` and `kubeconfigSecrets.argocd` so a controller can reach a remote Kargo or Argo CD cluster ([`values.yaml`](https://github.com/akuity/kargo/blob/v1.12.6/charts/kargo/values.yaml)) **(verified)**.

Sharding exists to reach many Argo CD instances. A git-only setup does not talk to any Argo CD, so it needs no shard: **one standalone Kargo serves every cluster**. Shards only become useful if a later ADR adds `argocd-wait` or `argocd-update` on clusters other than the Kargo host.

### Custom resources

The chart at `v1.12.6` ships these CRDs ([`charts/kargo/resources/crds`](https://github.com/akuity/kargo/tree/v1.12.6/charts/kargo/resources/crds)) **(verified)**:

| Kind | Scope | Purpose in this plan |
| --- | --- | --- |
| `Project` | cluster | One per tenant. Creates (or adopts) a namespace of the same name; the namespace is the tenancy and RBAC boundary. |
| `ProjectConfig` | namespaced, one per Project | Promotion policies (auto-promotion per Stage selector), promotion windows, webhook receivers, auto-rollback. |
| `Warehouse` | namespaced | Subscribes to the tenant image and OCI chart (and optionally a Git path); emits Freight. |
| `Freight` | namespaced | Immutable set of artifact revisions (image tag or digest, chart version, commit) that moves through Stages. |
| `Stage` | namespaced | One promotion target. Here: one Stage per tenant and cluster. Holds `requestedFreight`, `promotionTemplate` and optional `verification`. |
| `Promotion` | namespaced | One run of a Stage's steps for one Freight. Runs inside the controller process. |
| `PromotionTask` | namespaced | Reusable list of steps inside one Project. |
| `ClusterPromotionTask` | cluster | Reusable list of steps for every Project. Here: the platform-owned "render and open a pull request" task. |
| `ClusterConfig` | cluster | Cluster-wide settings, for example the default Git committer identity and webhook receivers. |
| `PromotionRequest`, `Target` | namespaced | New in the `v1.12` source: a Stage that promotes to several Targets (for example clusters). Not in the `v1.12` user docs **(verified: absent from `docs/` at the tag)**. Treat as unreleased; do not design on it. |

`AnalysisTemplate` and `AnalysisRun` come from Argo Rollouts (`argoproj.io/v1alpha1`); Kargo ships only Go stubs for them ([`api/stubs/rollouts`](https://github.com/akuity/kargo/tree/v1.12.6/api/stubs/rollouts)) **(verified)**.

Promotions to one Stage run one at a time: the Stage tracks a single `status.currentPromotion`, and while a verification runs "no other Promotions to that Stage will run" ([verification guide](https://docs.kargo.io/user-guide/how-to-guides/verification)) **(verified)**.

## Does Kargo need Argo CD?

No. The FAQ and the core concepts page name Argo CD as one example of a GitOps agent ([core concepts](https://docs.kargo.io/user-guide/core-concepts)) **(verified)**. The chart flag `controller.argocd.integrationEnabled` (default `true`) turns the integration on; if Argo CD is not installed, the controller disables it at boot, but the docs recommend setting it to `false` explicitly because the controller then gets fewer permissions ([common configurations](https://docs.kargo.io/operator-guide/advanced-installation/common-configurations)) **(verified)**. The same holds for `api.rollouts.integrationEnabled` and `controller.rollouts.integrationEnabled`.

Recommended values for this plan: `controller.argocd.integrationEnabled: false`, and Rollouts integration `false` until verification is adopted.

### What is lost without `argocd-update`

Note: the step is named `argocd-update`, not `argo-cd-update` ([promotion steps](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/)) **(verified)**.

1. **Health.** `argocd-update` registers a health check that follows the updated Application's health as Argo CD reports it ([Argo CD integration](https://docs.kargo.io/user-guide/how-to-guides/argo-cd-integration)) **(verified)**. Without it, the Promotion records no health checks. In the source, the aggregating checker starts at `Healthy` and only degrades through the checks it runs; with zero checks the Stage becomes `Healthy` right after a successful Promotion ([`pkg/health/aggregating_checker.go`](https://github.com/akuity/kargo/blob/v1.12.6/pkg/health/aggregating_checker.go), [`pkg/controller/stages/regular_stages.go`](https://github.com/akuity/kargo/blob/v1.12.6/pkg/controller/stages/regular_stages.go)) **(verified in source)**. "Healthy" therefore means "the pull request is merged", not "the pods run".
2. **Verification timing.** Verification starts after a successful Promotion and, where Argo CD Applications are involved, after they are `Healthy` ([verification guide](https://docs.kargo.io/user-guide/how-to-guides/verification)) **(verified)**. Without the health gate it starts at merge time, before Argo CD has synced.
3. **Auto-promotion gating.** A downstream Stage accepts Freight that is verified upstream (`requestedFreight[].sources.stages`). If a Stage has no `verification` block, the Freight counts as verified with no check ("If there is no verification configuration for the Stage, then the verification is automatically considered successful", `regular_stages.go`) **(verified in source)**. So, without verification, Freight becomes eligible downstream the moment the upstream pull request is merged.
4. **Sync trigger.** Without `argocd-update`, Argo CD picks up the merge on its own poll interval (default three minutes, **unverified**) or through a webhook. This is what ADR-0008 accepted.

`argocd-wait` is a read-only middle ground: it waits for Applications to reach `health`, `sync` and `operation` conditions, needs no `authorized-stage` annotation, but registers no health check ([argocd-wait](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/argocd-wait)) **(verified)**. It needs the controller to read Argo CD `Application`s, so it only works for the cluster that hosts Kargo, or through a shard or `kubeconfigSecrets.argocd` per remote Argo CD. It does not write to Argo CD, so it does not break the git-only rule, but it does break "Kargo needs no access to target clusters". This study keeps it out of scope.

## Git-only promotion, end to end

### Shape

```text
app repo (gsuquet/<app>) --CI--> ghcr.io image + OCI chart
                                       |
                       Warehouse (Project <tenant>) polls
                                       v
                                    Freight
                                       |
             Stage <tenant>/<cluster> (manual or auto-promotion)
                                       v
 Promotion: git-clone gsuquet/gitops -> oci-download + untar chart
            -> delete tenants/<tenant>/<cluster>/ -> helm-template into it
            -> git-commit -> git-push kargo/promotion/<promotion>
            -> git-open-pr to main -> git-wait-for-pr (human merges)
                                       v
            Argo CD on <cluster> syncs tenants/<tenant>/<cluster>/
```

### Resources

The tenant Project, Warehouse and Stages are generated by `infra` from `gitops/tenants/<tenant>.yaml` and live on the Kargo host cluster (see [Multi-tenancy](#multi-tenancy)). The step list is a `ClusterPromotionTask` owned by the platform, so a tenant cannot change where its promotion writes.

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: app
  namespace: kargo-demo # Project namespace of tenant "demo"
spec:
  subscriptions:
    - image:
        repoURL: ghcr.io/gsuquet/demo
        imageSelectionStrategy: SemVer
        constraint: ^1.0.0
    - chart:
        repoURL: oci://ghcr.io/gsuquet/charts/demo # OCI: no chart name
        semverConstraint: ^1.0.0
```

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: ClusterPromotionTask
metadata:
  name: render-tenant-pull-request
spec:
  vars:
    - name: tenant
    - name: cluster
    - name: namespace
    - name: imageRepo
    - name: chartRepo
    - name: gitopsRepo
      value: https://github.com/gsuquet/gitops.git
  steps:
    - uses: git-clone
      config:
        repoURL: ${{ vars.gitopsRepo }}
        checkout:
          - branch: main
            path: ./gitops
    - uses: oci-download
      config:
        imageRef: ${{ vars.chartRepo }}:${{ chartFrom(vars.chartRepo).Version }}
        outPath: ./chart.tgz
    - uses: untar
      config:
        inPath: ./chart.tgz
        outPath: ./chart
        stripComponents: 1
    # git-clear would wipe the whole gitops checkout: delete only this tenant/cluster path.
    - uses: delete
      config:
        path: ./gitops/tenants/${{ vars.tenant }}/${{ vars.cluster }}
    - uses: helm-template
      config:
        path: ./chart
        releaseName: ${{ vars.tenant }}
        namespace: ${{ vars.namespace }}
        valuesFiles:
          - ./chart/values-${{ vars.cluster }}.yaml
        ignoreMissingValueFiles: true
        setValues:
          - key: image.tag
            value: ${{ imageFrom(vars.imageRepo).Tag }}
        outPath: ./gitops/tenants/${{ vars.tenant }}/${{ vars.cluster }}
        outLayout: flat
    - uses: git-commit
      config:
        path: ./gitops
        message: "chore(${{ vars.tenant }}): promote ${{ imageFrom(vars.imageRepo).Tag }} to ${{ vars.cluster }}"
    - uses: git-push
      as: push
      config:
        path: ./gitops
        generateTargetBranch: true # kargo/promotion/<promotion name>
    - uses: git-open-pr
      as: open-pr
      config:
        repoURL: ${{ vars.gitopsRepo }}
        sourceBranch: ${{ task.outputs.push.branch }}
        targetBranch: main
        labels: ["promotion", "tenant/${{ vars.tenant }}"]
    # No retry.timeout: see "Stale promotion pull requests" below.
    - uses: git-wait-for-pr
      if: ${{ status('open-pr') != 'Skipped' }}
      config:
        repoURL: ${{ vars.gitopsRepo }}
        prNumber: ${{ task.outputs['open-pr'].pr.id }}
```

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: pi
  namespace: kargo-demo
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: app
      sources:
        stages: [kind] # pi only takes Freight already promoted to kind
  promotionTemplate:
    spec:
      steps:
        - task:
            name: render-tenant-pull-request
            kind: ClusterPromotionTask
          vars:
            - name: tenant
              value: demo
            - name: cluster
              value: pi
            - name: namespace
              value: demo
            - name: imageRepo
              value: ghcr.io/gsuquet/demo
            - name: chartRepo
              value: oci://ghcr.io/gsuquet/charts/demo
```

The YAML above is a design sketch. Every field name was checked against the `v1.12.6` reference docs ([git-clone](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-clone), [oci-download](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/oci-download), [helm-template](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/helm-template), [git-push](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-push), [git-open-pr](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-open-pr), [git-wait-for-pr](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-wait-for-pr), [promotion tasks](https://github.com/akuity/kargo/blob/v1.12.6/docs/docs/50-user-guide/60-reference-docs/20-promotion-tasks.md)) **(verified)**, but the manifests were not applied to a cluster **(unverified as a whole)**.

### Step facts that shape the design

- `git-push` with `generateTargetBranch: true` pushes to `kargo/promotion/<promotion name>` and outputs `branch` and `commit` **(verified)**. The controller default push integration policy is `RebaseOrMerge` since `v1.12.0` ([v1.12.0 notes](https://docs.kargo.io/release-notes/v1.12.0)) **(verified)**. `force` defaults to `false`; keep it so.
- `git-open-pr` fails if `targetBranch` does not exist, and `createTargetBranch` was removed in `v1.12.0` **(verified)**. The step is skipped when the source and target branches have no difference, hence the `if:` on the wait step **(verified)**.
- `git-wait-for-pr` keeps the Promotion `Running` while the pull request is open, polls every `30s` by default (minimum `10s`), waits forever unless `retry.timeout` is set, and **fails the Promotion if the pull request is closed without merge** (not retried) **(verified)**. Because Promotions to a Stage run one at a time, an open pull request blocks the next Promotion to that Stage until it is merged, closed or the Promotion is aborted.
- When a step's `retry.timeout` elapses, "the `Promotion` fails" ([promotion templates](https://docs.kargo.io/user-guide/reference-docs/promotion-templates), [git-wait-for-pr](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-wait-for-pr)) **(verified)**. Neither page says that Kargo closes the pull request or deletes the `kargo/promotion/*` branch, so both are assumed to stay open **(unverified)**.

### Stale promotion pull requests

A timed-out Promotion leaves an open pull request behind. If a human merges it later, Argo CD deploys Freight that Kargo records as a failed Promotion, not as Freight in use: Kargo and Git diverge, and the downstream Stage does not see that Freight as promoted upstream. Proposal:

- **No `retry.timeout`** on `git-wait-for-pr` (the sketch above sets none). A stale promotion is ended on purpose: abort the Promotion in Kargo and close the pull request; the closed pull request also fails the Promotion on the next poll.
- **Enable "Automatically delete head branches"** on `gsuquet/gitops`, so merged promotion branches disappear; closed-unmerged branches are deleted by hand or by a scheduled workflow in `gsuquet/gitops` that closes promotion pull requests older than N days and deletes their branches.
- **Merge only while the Promotion is `Running`.** A pull request whose Promotion is gone (failed, aborted, or lost with a kind host) must be closed, not merged: promote the Freight again instead. The pull request CI (see [Pull request checks on `gsuquet/gitops`](#pull-request-checks-on-gsuquetgitops)) cannot see Kargo state, so this is a human rule **(proposal)**.
- `git-clear` empties the **whole** working tree ([promotion steps](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/)) **(verified)**. In a shared `gsuquet/gitops` checkout use `delete` on `tenants/<tenant>/<cluster>/` instead, so stale files from a previous render disappear without touching other tenants.
- `helm-template` takes a local chart directory (`path` must hold a `Chart.yaml`) **(verified)**. An OCI chart therefore needs `oci-download` (accepts `oci://...:tag`, uses Helm credentials) and `untar` first **(verified)**. `includeCRDs` defaults to `false`, which suits tenants: tenants may not ship cluster-scoped resources anyway.
- `kustomize-build` is the alternative render step for tenants that use Kustomize; it renders a directory with a `kustomization.yaml` **(verified)**. It would need a `git` subscription on the app repository (with `includePaths`) instead of a chart subscription.
- `git-merge-pr` exists (beta) **(verified)**. It must not be used here: the rule is that a human merges.
- SSH repository URLs are deprecated since `v1.10.0` with removal announced for `v1.13.0` (which will not exist, so `v2.0.0`) **(verified)**. Use HTTPS URLs only.
- Steps marked Enterprise (`wait-for-approval`, `send-message`, the `gh-*` and `gha-*` steps, `tf-*`, ServiceNow, Jira) are not in the open-source build **(verified)**. Nothing in this design needs them.

### Rendered manifests and "a human merges"

- The render runs inside the Kargo controller, and the output is plain YAML committed to `gsuquet/gitops`. Argo CD on each cluster applies plain YAML, as for the platform. The pattern holds.
- The pull request is the review point. Kargo cannot merge if: no step uses `git-merge-pr`, the credential cannot bypass branch protection, and `gsuquet/gitops` `main` requires a pull request with one approval. GitHub's own auto-merge must stay disabled on `gsuquet/gitops`.
- Kargo records the Freight as "in use" by the Stage only after the merge, so Kargo's view matches Git.
- A closed pull request fails the Promotion; the Freight stays available for a new Promotion.
- Two tenants, or two clusters of one tenant, can have open pull requests at the same time: each writes a different path, and each pull request comes from its own branch. Conflicts only arise for the same `tenants/<tenant>/<cluster>/` path, which the one-at-a-time rule per Stage already prevents.

### Pull request checks on `gsuquet/gitops`

Tenant charts render inside the Kargo controller, outside `infra`'s `manifests:check`, kubeconform and Conftest. Without a check on `gsuquet/gitops`, a buggy or malicious chart output is stopped only by the human review and, at sync time, by the tenant `AppProject` (ADR-0009). The shared GitHub App can also write any path of the repository (see [Credentials](#credentials)). So `gsuquet/gitops` needs its own pull request CI, set as a **required status check** on `main` **(proposal)**:

- **Path scope**: every changed path is under `tenants/<tenant>/<cluster>/`, where `<tenant>` matches the pull request's `tenant/<tenant>` label and `<cluster>` is a cluster the tenant is onboarded on. A promotion pull request touches exactly one `tenants/<tenant>/<cluster>/` directory. Pull requests from `kargo/promotion/*` branches that touch anything else fail.
- **kubeconform** on the changed directory, with the CRD schemas the platform ships (ESO, Gateway API).
- **Conftest** with tenant rules shared with `infra` (ADR-0009, ADR-0010, ADR-0016): no cluster-scoped kind, no `Namespace`, no `NetworkPolicy` or `CiliumNetworkPolicy`, no `Secret` with `data` or `stringData`, no `SecretStore` or `ClusterSecretStore`, every `ExternalSecret` on `SecretStore` `secrets`.
- **CODEOWNERS** per `tenants/<tenant>/` once there is more than one human (open question 10).

The policies live in one place (proposal: `infra`'s `policy/`, pulled by the `gsuquet/gitops` workflow at a pinned commit) so the two repositories cannot drift. This is a new workflow in `gsuquet/gitops`, outside this repository's CI scope (ADR-0019).

## Credentials

| Need | Credential | Scope |
| --- | --- | --- |
| Clone, push branches, open and read pull requests on `gsuquet/gitops` | GitHub App installation token | Repository `gsuquet/gitops` only |
| Read public images and OCI charts on `ghcr.io` | none for public packages (**unverified** for anonymous OCI pulls through Kargo) | - |
| Read public app repositories (if a `git` subscription is used) | none | - |
| Kargo admin account (kind only) | `api.adminAccount.passwordHash` and `tokenSigningKey` | kind cluster |
| UI login on a long-lived cluster | OIDC through Dex with a GitHub OAuth App, or an OIDC provider with PKCE | owner only |

**GitHub App over a personal access token.**

- Kargo supports GitHub App credentials in a `Secret` labelled `kargo.akuity.io/cred-type: git` with `githubAppClientID` (preferred over the deprecated `githubAppID`), `githubAppPrivateKey`, `githubAppInstallationID` and `repoURL` ([managing secrets](https://docs.kargo.io/operator-guide/security/managing-secrets)) **(verified)**. The CLI cannot create this Secret; it must come from GitOps or `kargo apply` **(verified)**. Here it comes from an `ExternalSecret` on the store `secrets` (ADR-0016), with the label set through the ESO target template.
- Pull requests opened by an App are not authored by the owner, so the owner can approve and merge them under a "require one approval" rule. With the owner's personal token, the owner would be the author and GitHub does not let an author approve their own pull request (**unverified**, standard GitHub behaviour), which would push toward weaker branch protection.
- App installation tokens are short-lived and are not tied to a user ([managing secrets](https://docs.kargo.io/operator-guide/security/managing-secrets) notes that "the App's permissions are not tied to a specific GitHub user") **(verified)**; the one-hour token lifetime is **(unverified)**.
- Permissions: the docs only state **Contents: Read and write** **(verified)**. Opening and waiting for pull requests also needs **Pull requests: Read and write** and **Metadata: Read** (**unverified**, inferred from the GitHub API). Install the App on `gsuquet/gitops` only: the App gets its permissions on every repository it is installed on **(verified)**.
- Put the credential in the shared resources namespace (`kargo-shared-resources`): every Project can use it, and no Project user can read it, because shared credentials cannot be referenced by `secret()` **(verified)**. The experimental `kargo.akuity.io/github-token-scopes` annotation (since `v1.8.0`) restricts which repositories each Project can get a token for **(verified)**; with one repository it adds nothing yet. It does not restrict paths: any Project could write any path of `gsuquet/gitops`. The path boundary is the required pull request check described in [Pull request checks on `gsuquet/gitops`](#pull-request-checks-on-gsuquetgitops), backed by the human review.
- **Lookup precedence.** Kargo searches the Project's own namespace first and the shared resources namespace only if nothing matches; within a namespace, exact `repoURL` matches win over regex matches, then lexical order by Secret name ([managing secrets](https://docs.kargo.io/operator-guide/security/managing-secrets)) **(verified)**. Anyone who can create a Secret in a Project namespace can therefore override the platform credential for that Project, for example with their own token pushing elsewhere or with more scopes. Rules:
  - tenants get no `create`/`update` on `Secret`s in their Project namespace. `kargo-viewer` permissions "do not extend to credentials and other project `Secret`s" and `kargo-promoter` cannot edit pipeline resources ([access controls](https://docs.kargo.io/user-guide/security/access-controls)) **(verified)**; the exact Secret verbs of the built-in roles are not documented **(unverified)**, so check them with `kargo get role <name> --as-kubernetes-resources` in slice 1. `kargo-admin` manages "all aspects of the project" and stays with the platform;
  - `infra` renders no Secret and no `ExternalSecret` with the label `kargo.akuity.io/cred-type` into Project namespaces; Conftest fails any such object outside `kargo-shared-resources`.

## Where Kargo runs

Every cluster has its own Argo CD and there is no hub. Git-only Kargo needs none of them: it needs egress to GitHub and `ghcr.io`, and nothing on the target clusters. So Kargo is an **opt-in catalog component on exactly one cluster**, in standalone topology.

| Phase | Host | Consequence |
| --- | --- | --- |
| Slice 1 | one named kind cluster on a dev machine, promoting to an in-cluster Gitea, not to `gsuquet/gitops` (see below) | Builds and tests the flow offline with dummy credentials. Nothing reaches `gsuquet/gitops`. |
| Slice 2 | the first long-lived cluster (Talos on Pis, or GKE) | Same component, enabled in that cluster's `cluster.yaml`, with the real GitHub App credential. First and only Kargo that writes to `gsuquet/gitops`. The Pi cluster costs nothing extra; GKE adds compute cost and depends on the GKE policy risk of ADR-0010 (see [Network policy](#network-policy)). |

Notes:

- Kargo can promote the tenants of its own host cluster. It writes to Git only, so there is no bootstrap loop.
- A second Kargo on another cluster must not watch the same Projects, or both would open the same pull requests. One instance per platform, chosen in `cluster.yaml`.

### Kargo on kind (slice 1)

A kind host conflicts with three settled points, so slice 1 cannot simply promote to `gsuquet/gitops` from kind:

1. **No real credential on kind.** ADR-0016 and the proposed ADR-0020 (option G) give kind an ESO `fake` store with dummy values, offline and unattended. The GitHub App key behind the `ExternalSecret` would be a dummy, so `git-push`, `git-open-pr` and `git-wait-for-pr` against `gsuquet/gitops` cannot authenticate (and `git-clone` fails too while a dummy credential matches the repository URL, even though the repository is public **(unverified)**).
2. **Several kind clusters.** kind runs on several machines. If the `kargo` component were enabled in shared kind settings, each machine would run its own Kargo, and each would open the same promotion pull requests, which the "one instance per platform" rule forbids.
3. **Freight history is a promotion-order blocker, not only lost history.** Stage `pi` takes Freight with `sources.stages: [kind]`. After a kind host is recreated, no Freight has been promoted to the `kind` Stage on the new instance, so nothing is eligible for `pi` until `kind` is promoted again, even if `tenants/<tenant>/kind/` in Git already holds that version. The order between clusters lives in Kargo state, and a kind host loses it at every `cluster:down`.

Two ways out:

- **(a) Real key on kind by exception.** A person seeds the App key into one named kind cluster (outside ESO, or through a non-`fake` store on that one cluster), and only that cluster enables `kargo` in its own `cluster.yaml`, never in shared kind overrides. This breaks ADR-0016's "kind runs with no credentials" and ADR-0020's "any `fake` provider outside kind" Conftest symmetry, needs the owner's sign-off and its own ADR line, and still loses promotion order at every recreate (point 3).
- **(b) Offline sandbox on kind, real promotions from the first long-lived cluster (proposed).** On kind, Kargo promotes to a throwaway Gitea in the same cluster, holding a copy of the `gsuquet/gitops` layout, with dummy credentials from the `fake` store. `git-open-pr` and `git-wait-for-pr` support `provider: gitea`; Gitea does not support pull request labels yet ([git-open-pr](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-open-pr), issue [#6021](https://github.com/akuity/kargo/issues/6021)) **(verified)**, so the kind task variant drops `labels`. The Gitea component is kind-only and opt-in. Kargo writes to `gsuquet/gitops` only from the long-lived host. Gitea itself is not studied here: its chart, version and footprint are **(unverified)**.

With (b), `kind` is still a Stage of every tenant pipeline on the long-lived host: that Kargo writes `tenants/<tenant>/kind/` in `gsuquet/gitops`, and every kind cluster on every machine syncs it with its own Argo CD (the repository is public, so the kind Argo CD needs no credential). Promotion order (`kind` before `pi`) then lives on a host that is not recreated.
- The UI and API server need a route: an internal `HTTPRoute` on the cluster gateway, or `cloudflared` behind Cloudflare Access. The external webhooks server can stay disabled: Warehouse polling and the `30s` pull-request poll are enough for this volume.

### Network policy

The cluster default-deny applies to every namespace with the policy label. Kargo needs:

- egress from the controller, management controller, API server and the `garbage-collector` CronJob pods to the Kubernetes API (`kube-apiserver` entity; already in the baseline allows of ADR-0010, listed here so the component does not depend on it silently);
- egress from the controller (and the API server, which reads Freight sources for the UI, **unverified**) to `github.com`, `api.github.com`, `ghcr.io` and `pkg-containers.githubusercontent.com` on TCP 443. `ghcr.io` redirects blob downloads to `pkg-containers.githubusercontent.com` **(unverified, observed GitHub Packages behaviour; not in an allowed source)**;
- ingress from the Kubernetes API server (`kube-apiserver` / `remote-node` entity, depending on the distribution) to the webhooks server;
- ingress to the `api` Service from the gateway namespace (internal `HTTPRoute`) or from the `cloudflared` namespace, whichever exposes the UI;
- egress from verification Jobs (if adopted) to the URLs they probe;
- on kind with option (b) of [Kargo on kind](#kargo-on-kind-slice-1): egress from the controller to the in-cluster Gitea Service instead of GitHub.

The FQDN rules (`toFQDNs`) rely on Cilium learning the names from DNS answers, so the policy also needs a DNS rule (`rules.dns`) on the kube-dns egress for the `kargo` namespace: "`rules: dns` instructs Cilium to inspect and allow DNS lookups matching specified patterns" ([Cilium DNS-based policies](https://docs.cilium.io/en/stable/security/dns/), `stable`) **(verified)**; that `toFQDNs` does not work without it is **(unverified)**, and the Cilium version is not pinned here. On GKE, Dataplane V2 is a managed Cilium, and support for `CiliumClusterwideNetworkPolicy` and FQDN rules there is not guaranteed: ADR-0010 lists it as an unverified risk with a `NetworkPolicy` fallback, and a plain `NetworkPolicy` cannot express FQDN egress. **A GKE Kargo host depends on resolving that risk first** (GKE's own FQDN network policy is a separate GKE feature, **unverified**).

Kargo creates a namespace per Project. A namespace that Kargo creates at runtime is not in the rendered manifests, so Conftest never sees it, and it would lack the policy label. Kargo can **adopt** an existing namespace that carries `kargo.akuity.io/project: "true"` ([working with projects](https://docs.kargo.io/user-guide/how-to-guides/working-with-projects)) **(verified)**. So the tenant onboarding renders each Project namespace itself, with both labels, and Conftest checks it like any other namespace.

## Multi-tenancy

- **One Kargo `Project` per tenant**, named `kargo-<tenant>` to stay clear of the tenant workload namespaces on the same cluster (naming is a proposal).
- **Platform owns the pipeline.** Under ADR-0009 the clusters a tenant runs on come from the tenant lists of every `gitops/clusters/*/cluster.yaml`, not from the tenant file or from the Kargo host. So the render for the Kargo host **joins across all cluster files**: for every onboarded tenant (every `gitops/tenants/<tenant>.yaml` listed by at least one cluster), whatever cluster it runs on, it emits the Project namespace (with labels), `Project`, `ProjectConfig`, `Warehouse`, one `Stage` per cluster that lists the tenant, plus the shared `ClusterPromotionTask`. A tenant that does not run on the Kargo host still gets its Project there. These live in `gitops/clusters/<kargo-host>/rendered/`, applied by that cluster's Argo CD under the platform AppProject, not the tenant AppProject.
- **Promotion order is a new tenant file field** (extension of ADR-0009, which defines no order): for example `promotion: [kind, pi, gke]`. Stage `N` takes Freight from Stage `N-1` (`sources.stages`); the first Stage takes it from the Warehouse (`sources.direct: true`). The render fails if the list and the set of clusters that list the tenant differ: every cluster in `promotion` must list the tenant, and every cluster that lists the tenant must be in `promotion`. A render check (or Conftest on the Kargo host output) asserts exactly one `Stage` per (tenant, cluster) pair found across all `cluster.yaml` files. Whether the order is a list or a graph (two clusters in parallel) is open question 12.
- **Roles.** Each Project gets three built-in roles: `kargo-admin`, `kargo-promoter` (can promote Stages and approve Freight) and `kargo-viewer`, each a ServiceAccount, Role and RoleBinding trio; the custom `promote` verb on `stages` controls who can promote ([access controls](https://docs.kargo.io/user-guide/security/access-controls)) **(verified)**. OIDC claims map to these ServiceAccounts with the `rbac.kargo.akuity.io/claims` annotation; system-level roles (`kargo-admin`, `kargo-viewer`, `kargo-user`, `kargo-project-creator`) map through `api.oidc.*` chart values ([operator access controls](https://docs.kargo.io/operator-guide/security/access-controls)) **(verified)**.
- A tenant gets `kargo-promoter` and `kargo-viewer` on its own Project, never `kargo-admin`: with admin it could edit its Stage and point the task at another path. Today the owner is the only user, so this is future-proofing.
- **Auto-promotion** is set per Project with `ProjectConfig.spec.promotionPolicies` (`stageSelector` + `autoPromotionEnabled`) **(verified)**. With the "human merges" rule, auto-promotion only means "open the pull request automatically"; it never deploys on its own. A reasonable default: auto-promotion on for `kind`, off for later clusters.
- `requiredSoakTime` on `requestedFreight[].sources` holds Freight in an upstream Stage for a minimum time before downstream promotion ([verification guide](https://docs.kargo.io/user-guide/how-to-guides/verification)) **(verified)**. With no verification it is the only time-based gate between clusters.

## Verification without `argocd-update`

- A Stage `verification` lists `AnalysisTemplate`s (Argo Rollouts CRD) in the Project namespace. Providers include `job`, `web` and `prometheus` ([analysis templates](https://docs.kargo.io/user-guide/reference-docs/analysis-templates)) **(verified)**.
- **Argo Rollouts must be installed.** Kargo creates `AnalysisRun`s and reads their status; it only contains API stubs for these types, and its quickstart installs the Argo Rollouts chart **(verified in source)**. That Kargo does not execute `AnalysisRun`s itself, and so that the Rollouts *controller* (not just the CRDs) is required, is an inference from the source and from `controller.rollouts.controllerInstanceID` ("a cluster on which Jobs corresponding to an AnalysisRun ... will be executed") **(unverified as a statement in the docs)**. The tenant workloads do not need to use Rollouts **(verified)**.
- Without a health gate, the `AnalysisRun` starts at merge time. The template must therefore poll until the new version is live, for example a `web` metric on the tenant's public URL (through `cloudflared`) that checks a `/version` endpoint against the Freight tag, with `count`, `interval` and `failureLimit` large enough to cover the Argo CD sync delay. A `job` metric runs on the Kargo host cluster, so it cannot reach tenant workloads on other clusters except through public endpoints.
- While a Stage is verifying, other Promotions to it wait **(verified)**. Failed verification blocks the Freight from downstream Stages **(verified)**. Manual approval of Freight bypasses verification **(verified)**.
- Recommendation: no verification in slice 1 (no Rollouts controller, the human merge is the gate). Add `argo-rollouts` as an opt-in catalog component and `web`-metric verification when a tenant has a public endpoint and more than one cluster.

## Install footprint

From the chart at `v1.12.6` ([`values.yaml`](https://github.com/akuity/kargo/blob/v1.12.6/charts/kargo/values.yaml)) **(verified)**:

- Deployments: `api`, `controller`, `management-controller`, `webhooks-server`, `external-webhooks-server` (disable), `dex-server` (disabled unless OIDC through Dex); CronJob `garbage-collector`. Replicas default to `1`.
- Namespaces created by the chart: `kargo-system-resources` and `kargo-shared-resources` (set `createNamespace: false` and render them with the policy label instead).
- cert-manager is needed for the self-signed webhook, API and Dex certificates (`*.tls.selfSignedCert`) **(verified)**. cert-manager is a baseline component, so this is free.
- `resources: {}` for every component: **the chart sets no requests or limits** **(verified)**. The platform must set them.
- Images are built for `linux/amd64` and `linux/arm64` ([`.github/workflows/release.yaml`](https://github.com/akuity/kargo/blob/v1.12.6/.github/workflows/release.yaml)) **(verified)**, so the Pi 4 can run them.
- The CRDs are templated in the chart (`templates/crds.yaml`), so `helm template` renders them; the render step places them in sync wave `-1` as for any component.

**Pi 4 with 8 GiB.** No sizing data was found in the docs **(verified: absent)**, and the footprint was not measured: running Kargo on a local kind cluster needs the images from `ghcr.io`, which is outside the allowed fetch domains for this study. Estimate, **(unverified)**: five small Go processes at a few tens of MiB each when idle, with the controller spiking during Promotions because it runs `git clone` and `helm template` in-process. A total around 0.5 GiB of memory requests, plus about 0.2 GiB for an Argo Rollouts controller if adopted, might fit next to Talos, Cilium, Argo CD, cert-manager and ESO on 8 GiB. **Fits on a Pi is not established** and must not drive the decision until measured. Gate: in slice 1, measure every Kargo pod with `kubectl top pod` (metrics-server needed on kind) both idle and during a Promotion of a realistic tenant chart, record the peaks in this document, and only then fix requests and limits and accept the Pi as host.

## License, maturity and support

- Apache-2.0, open source, maintained by Akuity, with a commercial edition (Akuity Platform) that adds the Enterprise steps **(verified)**. About 3.8k GitHub stars on 2026-11-18 **(verified)**.
- `v1.0.0` exists since 2024; minor releases came about every two to three months (twelve minors from October 2024 to July 2026, per the [release support page](https://docs.kargo.io/release-support)) **(verified)**. Patch releases land for several minors at once (`v1.12.6`, `v1.11.10`, `v1.10.17`, `v1.9.17` on 2026-11-16) **(verified)**.
- Open-source users get fixes only in the latest release; the backport windows apply to the commercial builds **(verified)**. Plan to follow the latest minor.
- API group still `v1alpha1` **(verified)**. Each recent minor had breaking changes, for example `v1.12.0` removed the gRPC API, `git-open-pr.createTargetBranch` and `git-commit.author` **(verified)**.
- `v2.0.0` is next and "replaces the plumbing underneath Kargo -- how it stores state and how its components learn about changes"; the roadmap says GitOps-managed resources and promotion processes keep working, with upgrade details "coming soon" **(verified)**. Adopting `v1.12` now means one major upgrade soon.

## Alternatives

- **Renovate + CI render.** Renovate (already used in homelab) bumps the image tag or chart version in a source file; a GitHub Actions workflow renders and opens the pull request to `gsuquet/gitops`. No in-cluster footprint and no new credential model (the workflow uses a GitHub App token too). There is no Freight, no stage ordering and no verification: the order between clusters is a convention, and "promote what kind runs to pi" is a manual edit. Good enough for a few tenants and clusters; worse as clusters and tenants grow.
- **Argo CD Source Hydrator** (beta since Argo CD `v3.5`, current `v3.6.2`). Argo CD renders a `drySource` and pushes the result to a `syncSource` branch and path, which can be another repository; with `hydrateTo` it pushes to a staging branch, but it does **not** open a pull request ([source hydrator](https://argo-cd.readthedocs.io/en/stable/user-guide/source-hydrator/)) **(verified)**. It needs the commit server and write credentials in **every** cluster's Argo CD, two Argo CD instances cannot hydrate to the same repository and branch, and stale files are not removed **(verified)**. It has no promotion order between clusters. Poor fit: write credentials spread to N clusters, and something else must still open the pull requests.
- **Manual pull requests with a render task.** `mise run tenant:render <tenant> <cluster>` plus `gh pr create`. Zero footprint; all ordering is in the owner's head. A fallback for when Kargo is down.
- **GitHub Actions environments.** A `promote` workflow per tenant with `workflow_dispatch` and one environment per cluster with required reviewers. Gives ordering and approval without a cluster component, but no artifact discovery and no Freight history across clusters. **(unverified)** as a full design; not studied further.

## Recommendation

Adopt Kargo `v1.12.6` (open source), standalone, as the opt-in catalog component `kargo`, with Argo CD and Argo Rollouts integrations disabled, a platform-owned `ClusterPromotionTask` that renders and opens a pull request to `gsuquet/gitops`, a GitHub App installed only on `gsuquet/gitops`, a required pull request check on `gsuquet/gitops`, and no verification in slice 1. In slice 1, one named kind cluster runs Kargo against an in-cluster Gitea with dummy credentials; the first long-lived cluster is the only Kargo that writes to `gsuquet/gitops`. Stages come from a join across all `cluster.yaml` files, ordered by a new `promotion` list in the tenant file. Accept that Kargo knows "merged", not "deployed". Measure the footprint before choosing the Pi as host. Revisit before the `v2.0.0` upgrade.

## Open questions for the owner

1. **Kargo host after slice 1**: the Talos Pi cluster (free, home network) or GKE (managed, billed)? The Pi cluster is the default proposal, subject to the footprint measurement. A GKE host depends on resolving ADR-0010's GKE policy risk (Dataplane V2 support for `CiliumClusterwideNetworkPolicy` and FQDN egress).
2. **Tenant packaging**: must every tenant publish an OCI Helm chart, or must Kustomize sources in the app repository (`git` subscription + `kustomize-build`) also be supported in slice 1?
3. **Per-cluster tenant values**: in the chart (`values-<cluster>.yaml` shipped inside the chart, as sketched), in the app repository next to the code (needs a `git` subscription), or in `infra` (`gitops/tenants/<tenant>.yaml`)? Values must not live under `gsuquet/gitops/tenants/<tenant>/<cluster>/`, because Argo CD applies everything in that path.
4. **kind clusters**: several kind clusters run on several machines. Is `tenants/<tenant>/kind/` one shared target for all of them (proposed: yes, a Stage on the long-lived Kargo host), or is kind not a promotion Stage at all (only local renders)?
5. **Pull request wait**: keep `git-wait-for-pr` (Kargo history matches Git, but an open pull request blocks the Stage) with **no** `retry.timeout` (proposed; a timeout fails the Promotion but leaves the pull request open, see [Stale promotion pull requests](#stale-promotion-pull-requests)), or a timeout plus a scheduled cleanup workflow in `gsuquet/gitops`? Or end the Promotion at `git-open-pr` (Stage does not block, but Kargo marks Freight in use before the merge)?
6. **Auto-promotion**: on for the first Stage only (opens pull requests automatically), off for the others? Any `requiredSoakTime` between clusters?
7. **Verification**: accept "merged, not deployed" in slice 1 and add Argo Rollouts plus `web`-metric verification later, or require it from the first long-lived cluster?
8. **UI access**: OIDC through Dex with a GitHub OAuth App (one more credential), or keep the admin account behind Cloudflare Access? The docs say the admin account should never be enabled in production.
9. **GitHub App**: create one dedicated App for Kargo (proposed), or reuse an existing App? Who creates it, and is its private key stored in the secrets backend chosen in ADR-0020?
10. **Branch protection on `gsuquet/gitops`**: require one approval and disable auto-merge (proposed)? A CODEOWNERS file per `tenants/<tenant>/` for later tenants?
11. **Kargo `v2.0.0`**: start on `v1.12` now and upgrade, or wait for `v2.0.0` if it lands before slice 1 ends?
12. **Promotion order in the tenant file**: accept a `promotion: [kind, pi, gke]` list as an extension of ADR-0009 (needs an ADR-0009 follow-up, since 0009 is accepted)? Is a strict list enough, or must two clusters be able to take Freight from the same upstream in parallel?
13. **Slice 1 on kind**: (b) Kargo on one named kind cluster against an in-cluster Gitea with dummy credentials, real promotions only from the first long-lived cluster (proposed), or (a) a person-seeded real GitHub App key on one named kind cluster as a documented exception to ADR-0016, accepting that promotion order is lost at every `cluster:down`?
14. **`gsuquet/gitops` pull request CI**: accept a required check (path scope, kubeconform, Conftest) in `gsuquet/gitops`, with the policies sourced from `infra` at a pinned commit?
