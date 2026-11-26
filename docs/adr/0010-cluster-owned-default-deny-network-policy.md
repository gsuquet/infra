---
adr: 0010
title: Enforce a label-selected default deny network policy
status: accepted
date: 2026-11-18
rfc: docs/rfc/0010-cluster-owned-default-deny-network-policy.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0010. Enforce a label-selected default deny network policy

- Status: accepted on 2026-11-18 by gsuquet
- Context: isolating platform and tenant namespaces on every cluster, facing isolation that depends on each chart or tenant shipping a policy.
- Decision: we decided for a baseline catalog component `network-policy` on every cluster, GKE included (where `cluster-gke` creates every cluster with `enableCiliumClusterwideNetworkPolicy: true`), that renders one `CiliumClusterwideNetworkPolicy` denying ingress and egress for every endpoint in a namespace labelled `network.infra.gsuquet.com/policy: default-deny` (selected through `io.cilium.k8s.namespace.labels`), the baseline allows (egress to kube-dns and to the `kube-apiserver` entity) and the allow rules of platform components, with Conftest failing any rendered `Namespace` without the label except `kube-system`, and against a render-emitted policy layer, a Kubernetes `NetworkPolicy` per namespace and policies owned by each component or tenant, to achieve default deny that a missing namespace label turns into a CI failure, accepting explicit allow rules for every platform flow and a Cilium-specific policy.
- Consequences:
  - Good: one policy covers every labelled namespace, present and future; the label check turns a missing policy into a CI failure.
  - Good: amended 2026-11-19: the default deny and the platform policies moved from a render-emitted `rendered/platform/` layer into the baseline component `network-policy`, GKE included, so they are versioned, rendered and reviewed like any catalog component.
  - Bad: every platform flow (Argo CD to Git, cert-manager to ACME, cloudflared to Cloudflare, API server webhooks) needs an allow rule in `network-policy`.
  - Bad: the label selector fails open for namespaces created at runtime (Argo CD `CreateNamespace=true`, charts, operators, Kargo `Project` namespaces): every namespace must be a rendered `Namespace` with the label.
  - Bad: `hostNetwork` pods share the node identity and escape endpoint policies; Pod Security keeps tenants off the host network.
  - Bad: on GKE the policy CRD exists only on clusters created with `enableCiliumClusterwideNetworkPolicy: true` (enabling it later restarts `anetd`, with downtime); GKE allows no L7 rules, no node selectors and at most 1000 such policies per cluster.
  - Bad: GKE support for namespace-label selectors (`io.cilium.k8s.namespace.labels`) is unverified; the fallback is a Kubernetes `NetworkPolicy` default deny per labelled namespace, in its own RFC.
  - Bad: deferred: a runtime admission check (`ValidatingAdmissionPolicy`) for namespaces created outside Git, and the tenant allow rule format.
  - Bad: unresolved: platform `Namespace` manifests and tenant onboarding were decided on 2026-11-18 as a render-emitted `rendered/platform/` layer, but the render on `main` has no such layer and passes `gitops.tenants` to a `tenant` component; the owner decides which one renders them.
- Confidence: medium, GKE support of namespace-label selectors in `CiliumClusterwideNetworkPolicy` is not verified.
- Confirmation: Conftest on `gitops/clusters/*/rendered/**` fails a `Namespace` except `kube-system` without the policy label (on `main`); targets still to add: a Conftest rule for the Pod Security label, the `network-policy` component with `baseline: true` so the baseline check fails a `cluster.yaml` without it and every cluster, GKE included, renders `rendered/network-policy/`, and `cluster-gke` setting `enableCiliumClusterwideNetworkPolicy: true`.
- Revisit when: GKE Dataplane V2 rejects the policy, or Kubernetes `ClusterNetworkPolicy` becomes available on every target.

Source: [RFC 0010](../../docs/rfc/0010-cluster-owned-default-deny-network-policy.md), reviewed in https://github.com/gsuquet/infra/pull/5.

<!-- readability: allow-code L7 V2 -->
