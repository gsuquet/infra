---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Run one self-managed Argo CD per cluster

## Context and Problem Statement

Each cluster needs a GitOps controller. Argo CD can run once per cluster, or once in a hub that manages remote
clusters (classic multi-cluster or `argocd-agent`). Which topology does the platform start with?

## Decision Drivers

* A cluster must recover alone: no dependency on another cluster to sync.
* Few clusters at the start (one kind, one Talos, one GKE).
* Upstream, vanilla Argo CD: no fork, no custom image.

## Considered Options

* One vanilla Argo CD per cluster, managing itself
* One hub Argo CD managing all clusters
* `argocd-agent` with a control plane hub

## Decision Outcome

Chosen option: "One vanilla Argo CD per cluster, managing itself".

* Each cluster runs its own Argo CD, installed once by Terraform (ADR-0015), then managed by an Argo CD
  `Application` that points at `gitops/clusters/<name>/rendered/argocd/`.
* Argo CD manages its own components and the other components of the cluster; a cluster can opt some
  components out.

### Consequences

* Good, because each cluster is self-contained: losing one cluster does not stop syncs on another.
* Good, because the cluster's Argo CD is upgraded by a normal pull request to its rendered manifests.
* Bad, because there is one Argo CD UI and one set of credentials per cluster.
* Bad, because a broken Argo CD self-update needs a manual re-apply of `rendered/argocd/` (the bootstrap module
  applies the same files).
* Deferred: `argocd-agent` and any hub topology; revisit when the number of clusters makes per-cluster UIs costly.

### Confirmation

Each `gitops/clusters/<name>/cluster.yaml` lists `argocd`, and its rendered folder contains an `Application`
that manages `rendered/argocd/`.

## Pros and Cons of the Options

### One vanilla Argo CD per cluster, managing itself

* Good, because no cross-cluster credentials.
* Bad, because no single view of all clusters.

### One hub Argo CD managing all clusters

* Good, because one UI.
* Bad, because the hub needs API access to every cluster, and is a single point of failure.

### `argocd-agent` with a control plane hub

* Good, because pull-based agents with one UI.
* Bad, because more moving parts than the current number of clusters justifies.

## More Information

* [Argo CD declarative setup: manage Argo CD using Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
