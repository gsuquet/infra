---
adr: 0015
title: Limit bootstrap to cluster, Gateway CRDs, Cilium, Argo CD
status: accepted
date: 2026-11-18
rfc: docs/rfc/0015-bootstrap-boundary.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0015. Limit bootstrap to cluster, Gateway CRDs, Cilium, Argo CD

- Status: accepted on 2026-11-18 by gsuquet
- Decision: In the context of bringing a new cluster from nothing to GitOps, facing a node that needs a CNI before any pod and IaC state that would fight Argo CD, we decided for a cluster root `clusters/<name>/` that calls only `cluster-*` and `bootstrap-*` modules, in order: the cluster (`cluster-kind`, `cluster-talos` or `cluster-gke`), `bootstrap-gateway-api` from `rendered/gateway-api-crds/`, `bootstrap-cilium` from `rendered/cilium/` (both skipped on GKE), `bootstrap-argocd` from `rendered/argocd/` with its root `Application`, after which Argo CD adopts the same resources with no diff and installs everything else, and against every component in IaC with `helm_release` and a hand-installed Argo CD, to achieve one set of reviewed manifests and Argo CD as the single long-term owner, accepting a short period where IaC and Argo CD both know these resources.
- Consequences:
  - Good: the bootstrap reuses the reviewed rendered files: no second set of values.
  - Good: Argo CD is the single long-term owner of every in-cluster resource.
  - Bad: bootstrap modules must not revert Argo CD's later changes (apply once, or ignore changes after creation); the mechanism is an implementation choice of the modules.
  - Bad: destroying a cluster root must not depend on in-cluster resources Argo CD created (for example cloud load balancers); `cluster:down` documents the order.
- Confidence: high, the bootstrap applies the same files Argo CD manages, so adoption produces no diff.
- Confirmation: `clusters/<name>/` calls only `cluster-*` and `bootstrap-*` modules; no other in-cluster resource is in the IaC state.
- Revisit when: a component other than these three must exist before Argo CD runs.

Source: [RFC 0015](../../docs/rfc/0015-bootstrap-boundary.md), reviewed in https://github.com/gsuquet/infra/pull/5.
