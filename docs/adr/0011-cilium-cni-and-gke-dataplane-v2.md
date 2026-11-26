---
adr: 0011
title: Use Cilium on kind and Talos, Dataplane V2 on GKE
status: accepted
date: 2026-11-18
rfc: docs/rfc/0011-cilium-cni-and-gke-dataplane-v2.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0011. Use Cilium on kind and Talos, Dataplane V2 on GKE

- Status: accepted on 2026-11-18 by gsuquet
- Context: choosing a CNI per target for the network policy model and Gateway API, facing different default CNIs per distribution.
- Decision: we decided for Cilium with `kubeProxyReplacement=true` on kind (default CNI and kube-proxy disabled in the kind config) and Talos (Flannel and kube-proxy disabled in the machine config: `cluster.network.cni.name: none` and `cluster.proxy.disabled: true` before Talos 1.14, separate config documents from 1.14; API server at KubePrism `localhost:7445`; Talos cgroup settings), installed by IaC before Argo CD, and for GKE Dataplane V2 enabled at creation with `cilium` skipped on GKE, and against a self-installed Cilium on GKE and the distribution default CNIs, to achieve the same dataplane on kind and Talos and no CNI to operate in the cloud, accepting two dataplanes to reason about.
- Consequences:
  - Good: kind reproduces the Talos dataplane.
  - Good: GKE needs no CNI upgrades from this repository.
  - Bad: a Talos or kind node stays `NotReady` until Cilium runs: Cilium is installed by IaC before Argo CD.
  - Bad: Dataplane V2 has a restricted Cilium feature set; Cilium-specific features, possibly `CiliumClusterwideNetworkPolicy`, may differ on GKE (unverified).
  - Bad: the Talos machine config patch differs by Talos version.
- Confidence: medium, Dataplane V2 feature parity with Cilium is not verified.
- Confirmation: `cluster.yaml` of every GKE cluster omits `cilium`; every kind and Talos cluster lists it; a schema or policy check enforces it once `cluster.yaml` has a distribution field.
- Revisit when: Dataplane V2 lacks a feature the catalog needs, or Talos changes its CNI configuration again.

Source: [RFC 0011](../../docs/rfc/0011-cilium-cni-and-gke-dataplane-v2.md), reviewed in https://github.com/gsuquet/infra/pull/5.

<!-- readability: allow-code V2 -->
