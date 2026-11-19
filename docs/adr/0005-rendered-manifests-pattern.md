---
adr: 0005
title: Commit rendered manifests and apply them with sync waves
status: accepted
date: 2026-11-18
rfc: docs/rfc/0005-rendered-manifests-pattern.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0005. Commit rendered manifests and apply them with sync waves

- Status: accepted on 2026-11-18 by gsuquet
- Decision: In the context of delivering Helm-sourced components and tenant manifests through Argo CD, facing resources that are invisible in review when rendered at sync time, we decided for manifests rendered by `mise run manifests:render` into `gitops/clusters/<name>/rendered/<component>/` (one file per resource; deterministic: no template-time generated values, certificates from cert-manager or in-cluster generators, credentials from the `secrets` store; Helm hooks kept and mapped by Argo CD, unmappable hooks disabled or rendered with `--no-hooks` and recorded in the component) and applied by Argo CD as plain directory sources with sync waves (CRDs `-1`, ordinary resources `0`, child `Application` resources `1` or higher), everywhere including tenant manifests in `gsuquet/gitops`, and against Argo CD Helm sources and Config Management Plugins, to achieve reviewed and statically checked desired state with no chart repository needed at sync time, accepting large diffs and a render commit for every source change.
- Consequences:
  - Good: reviewers see every changed field of every cluster; Conftest and kubeconform check what reaches the cluster.
  - Good: the bootstrap applies the same `rendered/argocd/` files that Argo CD later adopts.
  - Bad: upgrades produce large diffs; Renovate chart bumps need a render commit.
  - Bad: output lands in public repositories: a chart rendering secret material at template time publishes it and breaks `manifests:check`.
  - Bad: Argo CD cannot tell a Helm install from an upgrade: `pre-install` hooks run on every sync.
- Confidence: high, the pattern ran in `homelab` and the tooling exists in `infra`.
- Confirmation: CI runs `mise run manifests:check` (two renders must match the committed files), betterleaks and the CRD sync wave `-1` set by the render (on `main`); targets still to add: a Conftest rule that fails any `Secret` with `data` or `stringData`, one that fails an Argo CD `Application` in `rendered/` with a `helm` source, and sync wave `1` or higher on child `Application` resources.
- Revisit when: rendered output makes the repository or pull request diffs too large to review, or Argo CD gains a reviewable render-at-sync mode.

Source: [RFC 0005](../../docs/rfc/0005-rendered-manifests-pattern.md), reviewed in https://github.com/gsuquet/infra/pull/5.
