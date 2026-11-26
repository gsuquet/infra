---
adr: 0004
title: Run one self-managed Argo CD per cluster
status: accepted
date: 2026-11-18
rfc: docs/rfc/0004-self-managed-argo-cd-per-cluster.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0004. Run one self-managed Argo CD per cluster

- Status: accepted on 2026-11-18 by gsuquet
- Context: choosing a GitOps topology for a few clusters, facing the choice between per-cluster, hub and `argocd-agent` topologies.
- Decision: we decided for one upstream vanilla Argo CD per cluster, installed once by the bootstrap and then managed by an Argo CD `Application` that points at `gitops/clusters/<name>/rendered/argocd/` (Argo CD manages itself and the other components; a cluster can opt some components out), and against a hub Argo CD and `argocd-agent`, to achieve clusters that sync and recover alone, accepting one UI and one set of credentials per cluster.
- Consequences:
  - Good: losing one cluster does not stop syncs on another; no cross-cluster credentials.
  - Good: Argo CD upgrades are ordinary pull requests to the cluster's rendered manifests.
  - Bad: one Argo CD UI and one set of credentials per cluster.
  - Bad: a broken Argo CD self-update needs a manual re-apply of `rendered/argocd/`, the files the bootstrap module applies.
- Confidence: high, the per-cluster model is the documented Argo CD self-management setup and fits a few clusters.
- Confirmation: each `gitops/clusters/<name>/cluster.yaml` lists `argocd`, and its rendered folder contains an `Application` that manages `rendered/argocd/`.
- Revisit when: the number of clusters makes per-cluster UIs and credentials costly; then evaluate `argocd-agent` or a hub.

Source: [RFC 0004](../../docs/rfc/0004-self-managed-argo-cd-per-cluster.md), reviewed in https://github.com/gsuquet/infra/pull/5.
