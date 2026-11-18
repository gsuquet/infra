---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Limit Terraform bootstrap to the cluster, Gateway API CRDs, Cilium and Argo CD

## Context and Problem Statement

A new cluster has no CNI and no GitOps controller. Something must install the minimum before Argo CD can take
over. Where is the line between Terraform and Argo CD?

## Decision Drivers

* Terraform state should not own in-cluster resources that Argo CD also manages.
* A node needs a CNI before any pod, including Argo CD, can run.
* The first install and later syncs should use the same manifests.

## Considered Options

* Terraform installs cluster, Gateway API CRDs, Cilium and Argo CD from rendered manifests; Argo CD adopts them
* Terraform installs every component with `helm_release`
* Terraform installs only the cluster; Argo CD installed by hand

## Decision Outcome

Chosen option: "Terraform installs the minimum from rendered manifests; Argo CD adopts them".

Order, per cluster root (`clusters/<name>/`):

1. `cluster-{kind,talos,gke}`: the cluster.
2. `bootstrap-gateway-api`: the Gateway API CRDs, from `rendered/gateway-api-crds/` (needed by Cilium's Gateway
   API support at start; skipped on GKE, which installs its own, ADR-0012).
3. `bootstrap-cilium`: Cilium, from `rendered/cilium/` (skipped on GKE).
4. `bootstrap-argocd`: Argo CD and its root `Application`, from `rendered/argocd/`.

Argo CD then adopts these resources (same manifests, so no diff) and installs everything else.

### Consequences

* Good, because the bootstrap reuses the reviewed rendered files: no second set of values.
* Good, because Argo CD is the single long-term owner of every in-cluster resource.
* Bad, because Terraform and Argo CD briefly both know these resources: the bootstrap modules must not revert
  Argo CD's later changes (apply once, or ignore changes after creation). The exact mechanism is an
  implementation choice of the bootstrap modules.
* Bad, because `terraform destroy` of the cluster root must not depend on in-cluster resources Argo CD created
  (for example cloud load balancers); `cluster:down` documents the order.

### Confirmation

`clusters/<name>/` calls only `cluster-*` and `bootstrap-*` modules; no other in-cluster resource is in
Terraform state.

## Pros and Cons of the Options

### Minimum from rendered manifests

* Good, because one source of truth for manifests.
* Bad, because adoption needs care.

### Every component in Terraform

* Good, because one tool.
* Bad, because no continuous reconciliation and huge state.

### Manual Argo CD install

* Good, because simple.
* Bad, because not reproducible.
