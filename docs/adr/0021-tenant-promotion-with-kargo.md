---
status: proposed
date: 2026-11-18
decision-makers: gsuquet
---

# Run one standalone Kargo for git-only tenant promotion

## Context and Problem Statement

ADR-0007 puts rendered tenant manifests in `gsuquet/gitops` under `tenants/<tenant>/<cluster>/`. ADR-0008 chose Kargo with git-only promotion steps and deferred where Kargo runs. Every cluster runs its own Argo CD, there is no hub, and a human merges every promotion pull request.

Where does Kargo run, how is it installed and configured, and what does a promotion do, given that Kargo gets no `argocd-update` step?

The full study is in [Kargo study](../research/kargo.md).

## Decision Drivers

* Git stays the only interface between Kargo and the clusters: no Kargo access to any target cluster or Argo CD.
* A human merges every promotion; nothing auto-merges.
* Rendered manifests pattern: the promotion commits plain YAML.
* A tenant cannot change where its promotion writes.
* Every namespace carries the policy label and uses the ESO store `secrets`; kind has no real credential (ADR-0010, ADR-0016).
* Tenant clusters come from the tenant lists of every `cluster.yaml` (ADR-0009).

## Considered Options

* A. One standalone Kargo on one cluster, git-only steps, platform-owned `ClusterPromotionTask`
* B. A Kargo per cluster, each promoting the tenants of its own cluster
* C. Sharded Kargo: control plane on one cluster, one controller next to each Argo CD
* D. No Kargo: Renovate plus a CI workflow that renders and opens the pull request
* E. Argo CD Source Hydrator on each cluster

## Decision Outcome

Proposed: **A**, because git-only promotion needs no Argo CD and no access to target clusters, so one instance can serve every cluster, and shards (C) only exist to reach several Argo CD instances.

* Kargo `v1.12.6` (open source, chart `oci://ghcr.io/akuity/kargo-charts/kargo` version `1.12.6`), standalone topology, as the opt-in catalog component `kargo`. Exactly one cluster enables it in its own `cluster.yaml`, never through shared kind settings.
* Slice 1: one named kind cluster runs Kargo against an in-cluster Gitea with dummy credentials from the `fake` store, so ADR-0016 holds and nothing reaches `gsuquet/gitops`. The first long-lived cluster then hosts the only Kargo that writes to `gsuquet/gitops`, with `kind` as an ordinary Stage that every kind cluster syncs. A person-seeded real key on kind (an ADR-0016 exception) was considered and is not proposed: it also loses promotion order at every `cluster:down`.
* Chart values: `controller.argocd.integrationEnabled: false`, `api.rollouts.integrationEnabled: false`, `controller.rollouts.integrationEnabled: false`, external webhooks server disabled, chart-created namespaces disabled in favour of rendered, labelled namespaces, explicit resource requests (the chart sets none).
* One Kargo `Project` per onboarded tenant, whatever cluster it runs on. The Kargo host render joins across all `gitops/clusters/*/cluster.yaml` to find each tenant's clusters (ADR-0009) and emits the Project namespace (labels `kargo.akuity.io/project: "true"` and the policy label, adopted by Kargo), `Project`, `ProjectConfig`, `Warehouse` and one `Stage` per cluster that lists the tenant.
* Promotion order comes from a new tenant file field, for example `promotion: [kind, pi, gke]`, an extension of ADR-0009 that needs its own follow-up. The render fails when the list and the clusters that list the tenant differ.
* One platform-owned `ClusterPromotionTask`: `git-clone` `gsuquet/gitops` -> `oci-download` + `untar` the tenant chart -> `delete` `tenants/<tenant>/<cluster>/` -> `helm-template` into it -> `git-commit` -> `git-push` with `generateTargetBranch` -> `git-open-pr` to `main` -> `git-wait-for-pr` with no `retry.timeout` (a timeout fails the Promotion but leaves the pull request open; stale promotions are aborted and their pull request closed).
* No `argocd-update`, `argocd-wait` or `git-merge-pr` step anywhere.
* Credential: a dedicated GitHub App installed only on `gsuquet/gitops` (Contents and Pull requests read and write), stored in `kargo-shared-resources` through an `ExternalSecret` on the store `secrets`. Kargo looks up credentials in the Project namespace before the shared one, so no tenant gets Secret write in its Project namespace and `infra` renders no Kargo credential there.
* `gsuquet/gitops` gets a required pull request check: changed paths limited to one `tenants/<tenant>/<cluster>/` matching the `tenant/<tenant>` label, kubeconform, and Conftest tenant rules (no cluster-scoped kinds, no `NetworkPolicy` or `CiliumNetworkPolicy`, no `Secret` data, `ExternalSecret` on store `secrets`). Tenant charts render inside Kargo, outside `infra`'s checks, so this is where their output is checked.
* Tenants get `kargo-promoter` and `kargo-viewer` on their Project, never `kargo-admin`.
* No verification in slice 1; Argo Rollouts is not installed.

The decision is left to the owner; the open questions of the study must be answered first.

### Consequences

* Good, because Kargo holds no credential for any cluster or Argo CD; its only write path is pull requests on one repository.
* Good, because one Kargo instance and one UI show every tenant's pipeline across all clusters.
* Good, because the GitHub App, not the owner, authors the pull requests, so the owner can approve under a "one approval required" rule.
* Good, because Kargo's "Freight in use" matches `main` of `gsuquet/gitops`: the Promotion ends at the merge.
* Bad, because Kargo knows "merged", not "deployed": with no health check the Stage is `Healthy` at merge time, and Freight without verification becomes eligible downstream at once.
* Bad, because an open promotion pull request blocks later Promotions to the same Stage until it is merged, closed or the Promotion is aborted.
* Bad, because the shared credential can write any path of `gsuquet/gitops`; the path boundary is the required pull request check plus the human review, not Kargo.
* Bad, because a new CI workflow and policy set must be maintained in `gsuquet/gitops`, and kept in step with `infra`'s policies.
* Bad, because slice 1 needs a kind-only Gitea component, and the kind sandbox does not exercise GitHub App authentication.
* Bad, because the API is `v1alpha1`, minors break things, and a `v2.0.0` that replaces the storage layer is next.
* Bad, because Kargo state (Freight, Promotion history and the promotion order between Stages) lives on one host; losing that host blocks downstream Stages until upstream Stages are promoted again. This is why kind does not host the real pipeline.
* Neutral, because the footprint is unmeasured; the Pi is not a host until measured (see Confirmation).

### Confirmation

* Conftest (or a render check) fails if any rendered `Stage`, `PromotionTask` or `ClusterPromotionTask` uses `argocd-update`, `argocd-wait` or `git-merge-pr`.
* At most one `cluster.yaml` enables the `kargo` component, and no shared kind settings enable it.
* A render check fails unless every (tenant, cluster) pair listed by any `cluster.yaml` has exactly one `Stage` on the Kargo host, and each tenant's `promotion` list equals the set of clusters that list it.
* Conftest fails any object labelled `kargo.akuity.io/cred-type` outside `kargo-shared-resources`.
* `gsuquet/gitops` `main` requires the path-scope, kubeconform and Conftest check to pass.
* Footprint gate: in slice 1, `kubectl top pod` on every Kargo pod, idle and during a Promotion, is recorded in the study before requests and limits are fixed and before a Pi cluster is accepted as host.
* Every Kargo Project namespace is rendered by `infra` and carries the policy label (Conftest namespace rule).
* `gsuquet/gitops` `main` requires a pull request with one approval; repository auto-merge is disabled; the GitHub App is not in any bypass list; "Automatically delete head branches" is enabled.

## Pros and Cons of the Options

### A. One standalone Kargo, git-only

* Good, because one install and one place to look.
* Good, because no cross-cluster network path or credential.
* Bad, because no deployment health signal.

### B. A Kargo per cluster

* Good, because each Kargo could use `argocd-wait` on its local Argo CD.
* Bad, because N installs, N UIs, and no promotion order across clusters: Freight cannot flow from one cluster's Stage to another's.

### C. Sharded Kargo

* Good, because each shard controller can read its local Argo CD for health.
* Bad, because it needs a ServiceAccount and token per shard reaching back to the control plane, which is the hub that the plan defers.
* Bad, because git-only promotion gains nothing from it.

### D. Renovate plus CI render

* Good, because no in-cluster component and tools already known from homelab.
* Bad, because no Freight, no stage order and no promotion history: "promote what kind runs to pi" is a manual edit.

### E. Argo CD Source Hydrator

* Good, because built into Argo CD (beta since `v3.5`).
* Bad, because it pushes but does not open pull requests, needs write credentials in every cluster's Argo CD, and has no order between clusters.

## More Information

* Refines ADR-0008. ADR-0008 names the step `argo-cd-update`; the Kargo step is `argocd-update`. Drop this note once ADR-0008 is corrected.
* Extends ADR-0009 (tenant file `promotion` field) and relies on ADR-0016 and the proposed ADR-0020 for the kind `fake` store.
* List this ADR in `docs/adr/README.md` once the index exists on `main`.
* Verification can be added later as a separate decision: an opt-in `argo-rollouts` component and `web`-metric `AnalysisTemplate`s that poll the tenant's public endpoint until the new version answers.
