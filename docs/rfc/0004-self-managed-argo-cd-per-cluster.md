---
rfc: 0004
title: Run one self-managed Argo CD per cluster
status: accepted
track: full
reversibility: two-way
author: gsuquet
deciders: gsuquet
created: 2026-11-18
updated: 2026-11-18
review: https://github.com/gsuquet/infra/pull/5
adr: docs/adr/0004-self-managed-argo-cd-per-cluster.md
supersedes: null
superseded-by: null
---

# RFC 0004: Run one self-managed Argo CD per cluster

## Summary

Each cluster runs its own vanilla Argo CD, installed once by the bootstrap and then managed by itself from the
cluster's rendered manifests. No hub and no `argocd-agent` for now.

## Context

- Each cluster needs a GitOps controller.
- Argo CD runs either once per cluster, or once in a hub that manages remote clusters (classic multi-cluster
  or `argocd-agent`).
- The platform starts with few clusters: one kind, one Talos, one GKE.

## Goals and non-goals

Goals:

- A cluster syncs and recovers with no dependency on another cluster.
- Argo CD upgrades are ordinary pull requests to rendered manifests.

Non-goals:

- `argocd-agent` and any hub topology.
- A single UI across clusters.

## Decision drivers

- A cluster recovers alone: no dependency on another cluster to sync.
- Few clusters at the start.
- Upstream, vanilla Argo CD: no fork, no custom image.

## Options considered

### One vanilla Argo CD per cluster, managing itself

- Good: no cross-cluster credentials; each cluster recovers alone.
- Bad: no single view of all clusters.

### One hub Argo CD managing all clusters

- Good: one UI.
- Bad: the hub needs API access to every cluster and is a single point of failure (recovers alone).

### argocd-agent with a control plane hub

- Good: pull-based agents with one UI.
- Bad: more moving parts than the number of clusters justifies (few clusters).

### Do nothing

No GitOps controller: manifests applied by hand or by IaC.

- Good: nothing to run.
- Bad: no continuous reconciliation, no drift repair.

## Proposal

```mermaid
flowchart LR
    B["bootstrap-argocd (IaC, once)"] -->|"applies"| R["gitops/clusters/{name}/rendered/argocd/"]
    R --> A["Argo CD"]
    A -->|"root Application"| R
    A -->|"child Applications, sync wave 1+"| O["other enabled components"]
```

Self-management: the bootstrap and Argo CD apply the same `rendered/argocd/` files.

| Rule | Value |
| --- | --- |
| Argo CD | upstream, vanilla, one per cluster |
| First install | the bootstrap (RFC 0015), from `rendered/argocd/` |
| After install | an Argo CD `Application` manages `rendered/argocd/` (itself) and the other components |
| Opt-out | a cluster can leave some components out of Argo CD management |
| Listed in | every `gitops/clusters/<name>/cluster.yaml` lists `argocd` |

## Operational impact

- Blast radius: one cluster: a broken Argo CD stops syncs on its own cluster only.
- Rollout: per cluster, at bootstrap; later upgrades are pull requests to `rendered/argocd/`.
- Rollback: revert the upgrade commit; when the self-update broke Argo CD, re-apply `rendered/argocd/` by hand, the same files the bootstrap applies (minutes).
- Migration: None: moving to a hub later only changes who applies the same rendered manifests.
- Security: no cross-cluster credentials; one set of Argo CD credentials per cluster.
- Cost: N/A: Argo CD runs on each cluster's existing nodes.
- Observability: Argo CD sync and health status of the root `Application` per cluster.

## Drawbacks and risks

- A broken Argo CD self-update cannot repair itself -> re-apply `rendered/argocd/` manually; the bootstrap module applies the same files.
- One Argo CD UI and one set of credentials per cluster -> acceptable while there are few clusters.

## Open questions

None.

## Decision

- Status: accepted on 2026-11-18 by gsuquet
- Decision: In the context of choosing a GitOps topology for a few clusters, facing the choice between per-cluster, hub and `argocd-agent` topologies, we decided for one upstream vanilla Argo CD per cluster, installed once by the bootstrap and then managed by an Argo CD `Application` that points at `gitops/clusters/<name>/rendered/argocd/` (Argo CD manages itself and the other components; a cluster can opt some components out), and against a hub Argo CD and `argocd-agent`, to achieve clusters that sync and recover alone, accepting one UI and one set of credentials per cluster.
- Consequences:
  - Good: losing one cluster does not stop syncs on another; no cross-cluster credentials.
  - Good: Argo CD upgrades are ordinary pull requests to the cluster's rendered manifests.
  - Bad: one Argo CD UI and one set of credentials per cluster.
  - Bad: a broken Argo CD self-update needs a manual re-apply of `rendered/argocd/`, the files the bootstrap module applies.
- Confidence: high, the per-cluster model is the documented Argo CD self-management setup and fits a few clusters.
- Confirmation: each `gitops/clusters/<name>/cluster.yaml` lists `argocd`, and its rendered folder contains an `Application` that manages `rendered/argocd/`.
- Revisit when: the number of clusters makes per-cluster UIs and credentials costly; then evaluate `argocd-agent` or a hub.

## Implementation

N/A: no cluster bootstrapped yet.

## References

- [Argo CD declarative setup: manage Argo CD using Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)

## Future work

- `argocd-agent` and any hub topology, when the number of clusters grows.
