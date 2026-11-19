---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Build infra as a greenfield successor of homelab

## Context and Problem Statement

`gsuquet/homelab` provisions the production k3s cluster `olympus` on Raspberry Pis with Ansible, and was half
way through a migration to a Terraform + GitOps design (`modules/`, `instances/`, `gitops/`). Legacy folders,
heavy documentation rules and the running production cluster make each structural change slow and risky.
How should the new platform design be delivered?

## Decision Drivers

* Production (`olympus`) must keep running until a replacement exists.
* The new design (Talos, rendered manifests, tenants, Gateway API) changes most of the tree.
* Lessons from `homelab` (modules, policies, schemas, render tasks) should be reused, not lost.

## Considered Options

* Greenfield `gsuquet/infra`, `homelab` frozen as reference
* Continue the in-place migration in `homelab`

## Decision Outcome

Chosen option: "Greenfield `gsuquet/infra`, `homelab` frozen as reference", because it removes the coupling
between the new design and the running cluster.

* `homelab` is frozen: no new features. It keeps running `olympus` until a Talos Raspberry Pi cluster defined in
  `infra` replaces it, then `homelab` is archived.
* `homelab`'s `modules/`, `gitops/`, `policy/`, `schemas/`, `docs/` and `.mise` tasks are a reference only: code is
  rewritten for `infra`, not copied blindly.

### Consequences

* Good, because `infra` starts clean, with no Ansible and no legacy folders.
* Good, because the production cluster is not touched by design experiments.
* Bad, because two repositories exist during the transition, and fixes to `olympus` still happen in `homelab`.
* Bad, because history of the reused ideas stays in `homelab`; ADRs here record the decisions again.
* Deferred: the cut-over plan from `olympus` to the Talos cluster (data, DNS, tunnels) gets its own ADR.

### Confirmation

`homelab` receives no feature pull request after this date; `infra` contains no `ansible/` folder.

## Pros and Cons of the Options

### Greenfield `gsuquet/infra`, `homelab` frozen as reference

* Good, because each decision can be made without migration constraints.
* Bad, because shared logic (render, policies) must be rewritten.

### Continue the in-place migration in `homelab`

* Good, because one repository and one history.
* Bad, because every change must stay compatible with the running cluster and the legacy folders.
