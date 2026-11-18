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

* The render emits, for every cluster (GKE included), a cluster layer in `gitops/clusters/<name>/rendered/platform/`
  that is not a catalog component and cannot be disabled in `cluster.yaml`. It holds the platform `Namespace`
  manifests, tenant onboarding (ADR-0009) and a `CiliumClusterwideNetworkPolicy` that selects every endpoint in
  a namespace carrying the policy label (Cilium exposes namespace labels to endpoints as
  `io.cilium.k8s.namespace.labels.<key>`) and denies ingress and egress by default.
* Baseline allows in the same layer: egress to kube-dns and to the Kubernetes API server (`kube-apiserver`
  entity).
* `kube-system` is excluded: it does not carry the label.
* Conftest fails any rendered `Namespace` (platform or tenant) that lacks the label, except `kube-system`.
* Every labelled namespace also carries a `pod-security.kubernetes.io/enforce` label: `restricted` for tenants
  (ADR-0009); platform namespaces default to `baseline` and opt down to `privileged` explicitly where a component
  needs host access (for example Cilium, if it ever runs outside `kube-system`).
* Tenants cannot create `NetworkPolicy` or `CiliumNetworkPolicy` (ADR-0009).

### Consequences

* Good, because one policy covers every labelled namespace, present and future.
* Good, because the label check turns a missing policy into a CI failure.
* Bad, because every platform component needs explicit allow rules (Argo CD to Git, cert-manager to ACME,
  cloudflared to Cloudflare, webhooks from the API server); these are written per component in the catalog.
* Bad, because the label selector fails open: a namespace created at runtime (Argo CD `CreateNamespace=true`, a
  chart or operator creating namespaces, Kargo `Project` namespaces) never passes through Conftest and, without
  the label, has no default deny. Namespaces must exist as rendered `Namespace` manifests; components that create
  namespaces at runtime are configured not to, or their namespaces are pre-rendered with the label.
* Bad, because endpoint policies do not cover `hostNetwork` pods: they share the node's identity. The Pod Security
  labels keep tenants off the host network; platform components that need it (Cilium itself) are reviewed per
  component.
* Deferred: a runtime admission check (a `ValidatingAdmissionPolicy` rejecting any `Namespace` created without the
  policy and Pod Security labels) to close the fail-open gap.
* Risk (unverified): the default deny is required on GKE too, but GKE Dataplane V2 is a managed Cilium and its
  support for `CiliumClusterwideNetworkPolicy` with namespace-label selectors is not verified against the GKE
  documentation. If unsupported, GKE gets a fallback (a Kubernetes `NetworkPolicy` default deny per labelled
  namespace, rendered in the same cluster layer) with its own ADR.
* Deferred: the allow-rule format for tenants (ingress from a Gateway, egress to external services).

### Confirmation

Conftest policy on `gitops/clusters/*/rendered/**`: each `Namespace` except `kube-system` has the policy label
and a Pod Security label; every cluster, GKE included, renders the default-deny policy in `rendered/platform/`.

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
