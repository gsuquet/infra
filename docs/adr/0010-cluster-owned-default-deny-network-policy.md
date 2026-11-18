---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Own network policy at the cluster layer with a label-selected default deny

## Context and Problem Statement

Namespaces are created by the platform and by tenants' onboarding. Without a policy, every pod can reach every
other pod. Who owns network isolation, and how is a namespace guaranteed to be covered?

## Decision Drivers

* Default deny, for platform and tenant namespaces alike.
* Isolation cannot depend on each chart or tenant shipping its own policy.
* A namespace that escapes the policy must fail CI, not be discovered later.

## Considered Options

* One `CiliumClusterwideNetworkPolicy` default deny selected by a namespace label, checked by Conftest
* A Kubernetes `NetworkPolicy` default deny rendered into each namespace
* Policies owned by each component or tenant

## Decision Outcome

Chosen option: "One `CiliumClusterwideNetworkPolicy` default deny selected by a namespace label".

* A cluster-layer component renders a `CiliumClusterwideNetworkPolicy` that selects every endpoint in a
  namespace carrying the policy label (Cilium exposes namespace labels to endpoints as
  `io.cilium.k8s.namespace.labels.<key>`) and denies ingress and egress by default.
* Baseline allows in the same layer: egress to kube-dns and to the Kubernetes API server (`kube-apiserver`
  entity).
* `kube-system` is excluded: it does not carry the label.
* Conftest fails any rendered `Namespace` (platform or tenant) that lacks the label, except `kube-system`.
* Tenants cannot create `NetworkPolicy` or `CiliumNetworkPolicy` (ADR-0009).

### Consequences

* Good, because one policy covers every labelled namespace, present and future.
* Good, because the label check turns a missing policy into a CI failure.
* Bad, because every platform component needs explicit allow rules (Argo CD to Git, cert-manager to ACME,
  cloudflared to Cloudflare, webhooks from the API server); these are written per component in the catalog.
* Bad, because namespaces must exist as rendered `Namespace` manifests: Argo CD's `CreateNamespace=true` and
  chart-created namespaces would bypass the Conftest check.
* Risk (unverified): on GKE, Dataplane V2 is Cilium-based but its support for `CiliumClusterwideNetworkPolicy`
  and namespace-label selectors was not verified against the GKE documentation. If unsupported, GKE needs a
  fallback (per-namespace Kubernetes `NetworkPolicy`) with its own ADR.
* Deferred: the allow-rule format for tenants (ingress from a Gateway, egress to external services).

### Confirmation

Conftest policy on `gitops/clusters/*/rendered/**`: each `Namespace` except `kube-system` has the label; each
cluster with Cilium renders the default-deny policy.

## Pros and Cons of the Options

### Cluster-wide Cilium policy selected by label

* Good, because one object, enforced by the CNI.
* Bad, because Cilium-specific.

### Kubernetes `NetworkPolicy` per namespace

* Good, because portable across CNIs, including GKE.
* Bad, because one copy per namespace, and the rendered set must stay complete.

### Policies owned by each component or tenant

* Good, because the owner knows the flows.
* Bad, because default deny depends on every owner remembering it.

## More Information

* [Cilium policy language](https://docs.cilium.io/en/stable/security/policy/language/)
