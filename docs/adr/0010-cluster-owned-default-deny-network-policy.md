---
adr: 0010
title: Enforce a label-selected default deny network policy
status: accepted
date: 2026-11-18
rfc: docs/rfc/0010-cluster-owned-default-deny-network-policy.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0010. Enforce a label-selected default deny network policy

- Status: accepted on 2026-11-18 by gsuquet, amended on 2026-11-19
- Decision: In the context of isolating platform and tenant namespaces on every cluster, facing isolation that depends on each chart or tenant shipping a policy, we decided for a baseline catalog component `network-policy` on every cluster, GKE included, that renders one `CiliumClusterwideNetworkPolicy` denying ingress and egress for every endpoint in a namespace labelled `network.infra.gsuquet.com/policy: default-deny` (selected through `io.cilium.k8s.namespace.labels`), the baseline allows (egress to kube-dns and to the `kube-apiserver` entity) and the allow rules of platform components, with Conftest failing any rendered `Namespace` without the label except `kube-system`, and against a render-emitted policy layer, a Kubernetes `NetworkPolicy` per namespace and policies owned by each component or tenant, to achieve default deny that a missing namespace label turns into a CI failure, accepting explicit allow rules for every platform flow and a Cilium-specific policy.
- Consequences:
  - Good: one policy covers every labelled namespace, present and future; the label check turns a missing policy into a CI failure.
  - Good: the default deny and the platform policies are versioned, rendered and reviewed like any catalog component.
  - Bad: every platform flow (Argo CD to Git, cert-manager to ACME, cloudflared to Cloudflare, API server webhooks) needs an allow rule in `network-policy`.
  - Bad: the label selector fails open for namespaces created at runtime (Argo CD `CreateNamespace=true`, charts, operators, Kargo `Project` namespaces): every namespace must be a rendered `Namespace` with the label.
  - Bad: `hostNetwork` pods share the node identity and escape endpoint policies; Pod Security keeps tenants off the host network.
  - Bad: GKE Dataplane V2 support for this policy is unverified; the fallback is a Kubernetes `NetworkPolicy` default deny per labelled namespace, in its own RFC.
- Confidence: medium, the GKE support of `CiliumClusterwideNetworkPolicy` with namespace-label selectors is not verified.
- Confirmation: Conftest on `gitops/clusters/*/rendered/**`: each `Namespace` except `kube-system` has the policy label and a Pod Security label; every cluster, GKE included, renders the default deny in `rendered/network-policy/`; a baseline check fails a `cluster.yaml` without `network-policy`.
- Revisit when: GKE Dataplane V2 rejects the policy, or Kubernetes `ClusterNetworkPolicy` becomes available on every target.

Source: [RFC 0010](../../docs/rfc/0010-cluster-owned-default-deny-network-policy.md), reviewed in https://github.com/gsuquet/infra/pull/5.
