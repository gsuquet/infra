---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Promote tenant releases with Kargo using git-only steps

## Context and Problem Statement

A tenant release moves through stages (for example kind, then Talos, then GKE). Kargo can promote by writing to
Git and by driving Argo CD directly (`argocd-update` step). How are releases promoted?

## Decision Drivers

* Git stays the only source of desired state; Argo CD syncs from Git without external triggers.
* Every promotion is a reviewable change in `gsuquet/gitops`.

## Considered Options

* Kargo with git-only promotion steps (render, then pull request to `gsuquet/gitops`)
* Kargo with the `argocd-update` step
* Manual pull requests, no promotion tool

## Decision Outcome

Chosen option: "Kargo with git-only promotion steps". A promotion renders the tenant manifests for the target
stage and opens a pull request to `gsuquet/gitops` under `tenants/<tenant>/<cluster>/`. Argo CD on the target
cluster syncs after the merge.

### Consequences

* Good, because each promotion is a commit with a diff.
* Good, because Kargo needs no write access to any Argo CD.
* Bad, because promotion latency includes the pull request merge and the Argo CD sync interval.
* Bad, because Kargo health verification cannot rely on the `argocd-update` step's feedback.
* Deferred: the `argocd-update` step, and where Kargo itself runs (it is an opt-in component, not baseline).
* To verify against the Kargo documentation when implementing: the exact names of the git promotion steps
  (`git-clone`, `git-commit`, `git-push`, `git-open-pr`, ...).

### Confirmation

No Kargo `Stage` in `infra` or `gsuquet/gitops` uses an `argocd-update` step.

## Pros and Cons of the Options

### Kargo with git-only steps

* Good, because GitOps purity and audit trail.
* Bad, because slower feedback.

### Kargo with `argocd-update`

* Good, because immediate sync and health feedback.
* Bad, because Kargo needs Argo CD credentials on every cluster.

### Manual pull requests

* Good, because no tool.
* Bad, because stage ordering and verification are manual.
