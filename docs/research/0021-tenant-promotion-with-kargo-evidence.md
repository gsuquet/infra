# Kargo evidence and sources

Detail of [RFC 0021](../rfc/0021-tenant-promotion-with-kargo.md). Study date 2026-11-18, against Kargo source tag `v1.12.6`.
"Verified" means checked against the linked source; "unverified" means prior knowledge, inference, or
unreachable source. The source links are in [sources](#sources).

The options, impact, risks and questions are stated in the RFC; this page holds only what the RFC leaves out.

## Option evidence

For each of the [options](../rfc/0021-tenant-promotion-with-kargo.md#options-considered):

- **A Kargo per cluster:** Freight cannot flow from one cluster's Stage to another's; N installs also
  mean N UIs.
- **Sharded Kargo:** the token per shard is a ServiceAccount token, and reaching back to the control
  plane is the hub the plan defers. [Architecture](0021-tenant-promotion-with-kargo-architecture.md#architecture)
  holds what sharding is for.
- **Renovate plus CI render:** Renovate bumps the image tag or chart version. The tools are known from
  homelab; the GitHub Actions workflow uses a GitHub App token too. "Promote what kind runs to pi"
  is a manual edit: enough for a few tenants, worse as they grow.
- **Argo CD Source Hydrator:** beta since `v3.5`, current `v3.6.2`. The `syncSource` is a branch and
  path, possibly in another repository (verified); it pushes, or with `hydrateTo` pushes to a staging branch,
  and opens no pull request (verified). It needs the
  commit server; two Argo CD instances cannot hydrate to one repository and branch; stale files stay;
  no order between clusters (verified).
- **GitHub Actions environments:** the workflow is started by `workflow_dispatch`.

## Impact evidence

For the [operational impact](../rfc/0021-tenant-promotion-with-kargo.md#operational-impact):

- **Blast radius:** losing the host loses Freight, history and promotion order; downstream Stages
  block until upstream ones are promoted again.
- **Rollback:** merged manifests stay in `gsuquet/gitops`.
- **Migration:** Warehouses rediscover Freight, but Stage history and promotion order are rebuilt only
  by promoting again. The `gsuquet/gitops` layout is unchanged.

## Risk evidence

For the [drawbacks and risks](../rfc/0021-tenant-promotion-with-kargo.md#drawbacks-and-risks):

- **`v1alpha1` API:** `v1.12.0` removed the gRPC API, `git-open-pr.createTargetBranch` and
  `git-commit.author`. `v2.0.0` "replaces the plumbing underneath Kargo -- how it stores state and how
  its components learn about changes"; the roadmap says GitOps-managed resources and promotion
  processes keep working; upgrade details "coming soon" (verified).
- **Single vendor:** Akuity, about 3.8k GitHub stars on 2026-11-18; minors every two to three months
  (twelve from October 2024 to July 2026), patches for several minors at once (verified). Open-source
  users get fixes only on the latest minor; backports are commercial.
- **Unverified facts to check in slice 1:** anonymous `ghcr.io` pulls, App permissions, built-in role
  Secret verbs, timed-out pull request left open, Rollouts controller requirement.

<!-- readability: allow-code V2 -->

## Open question detail

For the [open questions](../rfc/0021-tenant-promotion-with-kargo.md#open-questions):

- **Kargo host:** the Pi cluster is free; GKE is managed and billed, and needs the Dataplane V2 FQDN
  policy risk resolved.
- **Tenant packaging:** Kustomize sources need a `git` subscription and `kustomize-build`.
- **Per-cluster values:** the sketch uses `values-<cluster>.yaml` in the chart; the app repository needs
  a `git` subscription. Never under `tenants/<tenant>/<cluster>/` of `gsuquet/gitops`: Argo CD applies
  everything there.
- **kind Stage:** the target is `tenants/<tenant>/kind/`, the proposal is a Stage on the long-lived
  host; no Stage means local renders only.
- **Pull request wait:** the wait step is `git-wait-for-pr`. The cleanup is a scheduled workflow in
  `gsuquet/gitops`. Ending at `git-open-pr` does not block, but marks Freight in use before the merge.
- **Auto-promotion:** the soak time is the one between clusters.
- **Verification:** accept "merged, not deployed" in slice 1 and add Argo Rollouts and `web` metrics
  later, or require it from the first long-lived cluster?
- **UI access:** Dex uses a GitHub OAuth App, one more credential; the docs say never to enable the
  admin account in production.
- **Branch protection:** on `gsuquet/gitops`; CODEOWNERS per `tenants/<tenant>/` for later tenants.
- **Promotion order:** the list is `promotion: [kind, pi, gke]`; ADR-0009 is accepted, so it needs a
  follow-up RFC. Parallel means two clusters taking Freight from one upstream.
- **Slice 1 on kind:** Gitea sandbox (proposed), or a person-seeded real App key on one named kind
  cluster as an ADR-0016 exception, losing promotion order at every `cluster:down`?
- **Required check:** in `gsuquet/gitops`.

## Future work

Follow-ups of the RFC, out of its scope:

- Verification: opt-in `argo-rollouts` component and `web`-metric `AnalysisTemplate`s polling the
  tenant's public endpoint, once a tenant has a public endpoint and more than one cluster.
- `argocd-wait` or shards, only if a later decision accepts Kargo access to Argo CD.
- Kargo `v2.0.0` upgrade, and `PromotionRequest` and `Target` once documented.
- ADR-0009 follow-up RFC for the tenant file `promotion` field.
- Scheduled workflow in `gsuquet/gitops` closing stale promotion pull requests and their branches.
- GitHub Actions environments as a full design, if Kargo is rejected.

## Sources

- Kargo source at [`v1.12.6`](https://github.com/akuity/kargo/tree/v1.12.6), [releases](https://github.com/akuity/kargo/releases), [roadmap](https://docs.kargo.io/roadmap), [release support](https://docs.kargo.io/release-support), [v1.12.0 notes](https://docs.kargo.io/release-notes/v1.12.0)
- Chart: [`Chart.yaml`](https://github.com/akuity/kargo/blob/v1.12.6/charts/kargo/Chart.yaml), [`values.yaml`](https://github.com/akuity/kargo/blob/v1.12.6/charts/kargo/values.yaml), [CRDs](https://github.com/akuity/kargo/tree/v1.12.6/charts/kargo/resources/crds), [Rollouts stubs](https://github.com/akuity/kargo/tree/v1.12.6/api/stubs/rollouts), [release workflow](https://github.com/akuity/kargo/blob/v1.12.6/.github/workflows/release.yaml), [quickstart `kind.sh`](https://github.com/akuity/kargo/blob/v1.12.6/hack/quickstart/kind.sh) (tests with cert-manager `1.19.3`, Argo CD chart `9.4.3`, Argo Rollouts chart `2.40.6`; not requirements)
- Health in source: [`aggregating_checker.go`](https://github.com/akuity/kargo/blob/v1.12.6/pkg/health/aggregating_checker.go), [`regular_stages.go`](https://github.com/akuity/kargo/blob/v1.12.6/pkg/controller/stages/regular_stages.go)
- Operator docs: [architecture](https://docs.kargo.io/operator-guide/architecture), [basic installation](https://docs.kargo.io/operator-guide/basic-installation), [common configurations](https://docs.kargo.io/operator-guide/advanced-installation/common-configurations), [managing secrets](https://docs.kargo.io/operator-guide/security/managing-secrets), [operator access controls](https://docs.kargo.io/operator-guide/security/access-controls)
- User docs: [core concepts](https://docs.kargo.io/user-guide/core-concepts), [Argo CD integration](https://docs.kargo.io/user-guide/how-to-guides/argo-cd-integration), [verification](https://docs.kargo.io/user-guide/how-to-guides/verification), [working with projects](https://docs.kargo.io/user-guide/how-to-guides/working-with-projects), [access controls](https://docs.kargo.io/user-guide/security/access-controls), [analysis templates](https://docs.kargo.io/user-guide/reference-docs/analysis-templates), [promotion templates](https://docs.kargo.io/user-guide/reference-docs/promotion-templates), [promotion tasks](https://github.com/akuity/kargo/blob/v1.12.6/docs/docs/50-user-guide/60-reference-docs/20-promotion-tasks.md)
- Steps: [all](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/), [git-clone](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-clone), [oci-download](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/oci-download), [helm-template](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/helm-template), [git-push](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-push), [git-open-pr](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-open-pr), [git-wait-for-pr](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-wait-for-pr), [argocd-wait](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/argocd-wait), Gitea labels [issue 6021](https://github.com/akuity/kargo/issues/6021)
- Argo: [argo-helm](https://github.com/argoproj/argo-helm) (Rollouts chart `argo-rollouts-2.43.12`, app `v1.10.2`), [Argo CD releases](https://github.com/argoproj/argo-cd/releases) (`v3.6.2`), [Source Hydrator](https://argo-cd.readthedocs.io/en/stable/user-guide/source-hydrator/)
- [Cilium DNS-based policies](https://docs.cilium.io/en/stable/security/dns/)
- Related records: [RFC 0021 references](../rfc/0021-tenant-promotion-with-kargo.md#references)
