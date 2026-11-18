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
* Small footprint: the host can be a Raspberry Pi 4 with 8 GiB.
* Every namespace carries the policy label and uses the ESO store `secrets` (ADR-0010, ADR-0016).

## Considered Options

* A. One standalone Kargo on one cluster, git-only steps, platform-owned `ClusterPromotionTask`
* B. A Kargo per cluster, each promoting the tenants of its own cluster
* C. Sharded Kargo: control plane on one cluster, one controller next to each Argo CD
* D. No Kargo: Renovate plus a CI workflow that renders and opens the pull request
* E. Argo CD Source Hydrator on each cluster

## Decision Outcome

Proposed: **A**, because git-only promotion needs no Argo CD and no access to target clusters, so one instance can serve every cluster, and shards (C) only exist to reach several Argo CD instances.

* Kargo `v1.12.6` (open source, chart `oci://ghcr.io/akuity/kargo-charts/kargo` version `1.12.6`), standalone topology, as the opt-in catalog component `kargo`. Exactly one cluster enables it: kind in slice 1, then the first long-lived cluster.
* Chart values: `controller.argocd.integrationEnabled: false`, `api.rollouts.integrationEnabled: false`, `controller.rollouts.integrationEnabled: false`, external webhooks server disabled, chart-created namespaces disabled in favour of rendered, labelled namespaces, explicit resource requests (the chart sets none).
* One Kargo `Project` per tenant. `infra` renders, from the tenant file and the Kargo host `cluster.yaml`: the Project namespace (labels `kargo.akuity.io/project: "true"` and the policy label, adopted by Kargo), `Project`, `ProjectConfig`, `Warehouse` and one `Stage` per cluster of the tenant, in order.
* One platform-owned `ClusterPromotionTask`: `git-clone` `gsuquet/gitops` -> `oci-download` + `untar` the tenant chart -> `delete` `tenants/<tenant>/<cluster>/` -> `helm-template` into it -> `git-commit` -> `git-push` with `generateTargetBranch` -> `git-open-pr` to `main` -> `git-wait-for-pr`.
* No `argocd-update`, `argocd-wait` or `git-merge-pr` step anywhere.
* Credential: a dedicated GitHub App installed only on `gsuquet/gitops` (Contents and Pull requests read and write), stored in `kargo-shared-resources` through an `ExternalSecret` on the store `secrets`.
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
* Bad, because the shared credential can write any path of `gsuquet/gitops`; the path boundary is the human review, not Kargo.
* Bad, because the API is `v1alpha1`, minors break things, and a `v2.0.0` that replaces the storage layer is next.
* Bad, because Kargo state (Freight and Promotion history) is lost with a kind host; only Git keeps the result.
* Neutral, because the footprint on a Pi 4 is unmeasured; it is measured in slice 1 before requests are fixed.

### Confirmation

* Conftest (or a render check) fails if any rendered `Stage`, `PromotionTask` or `ClusterPromotionTask` uses `argocd-update`, `argocd-wait` or `git-merge-pr`.
* At most one `cluster.yaml` enables the `kargo` component.
* Every Kargo Project namespace is rendered by `infra` and carries the policy label (Conftest namespace rule).
* `gsuquet/gitops` `main` requires a pull request with one approval; repository auto-merge is disabled; the GitHub App is not in any bypass list.

## Pros and Cons of the Options

### A. One standalone Kargo, git-only

* Good, because smallest footprint and one place to look.
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

* Refines ADR-0008. ADR-0008 names the step `argo-cd-update`; the Kargo step is `argocd-update`.
* Verification can be added later as a separate decision: an opt-in `argo-rollouts` component and `web`-metric `AnalysisTemplate`s that poll the tenant's public endpoint until the new version answers.
