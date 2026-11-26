---
adr: 0003
title: Use kind, Talos and GKE as distributions per target
status: accepted
date: 2026-11-18
rfc: docs/rfc/0003-cluster-distribution-per-target.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0003. Use kind, Talos and GKE as distributions per target

- Status: accepted on 2026-11-18 by gsuquet
- Context: running one GitOps catalog on developer machines, owned hardware and a cloud, facing different constraints per target.
- Decision: we decided for kind on developer machines (a kind provider chosen in `cluster-kind`), Talos Linux on Raspberry Pis and local servers (`siderolabs/talos` provider, API only, no SSH, no Ansible) and managed GKE in the cloud (`hashicorp/google`; `cluster-gke` takes Spot pools, on-demand pools or both, per cluster, by input, and always creates the cluster with Dataplane V2 and `enableCiliumClusterwideNetworkPolicy: true`), with exactly one `cluster-*` module per target, and against k3s installed by Ansible and kubeadm with self-managed cloud VMs, to achieve immutable API-driven hardware, no cloud control plane to operate and a disposable local copy of the catalog, accepting three code paths that differ in CNI, storage and load balancing.
- Consequences:
  - Good: Talos is configured only through its API: machine configs are rendered by IaC, no SSH, no Ansible.
  - Good: GKE removes control plane operations; kind gives a disposable cluster to test the same catalog.
  - Good: amended 2026-11-19: each GKE cluster trades cost (Spot) against availability (on-demand) by input, with no module change.
  - Bad: the catalog handles CNI, storage and load balancing differences per cluster.
  - Bad: GKE owns its dataplane and, with Gateway API enabled (always on Autopilot), the Gateway API CRDs: the catalog skips `cilium` and `gateway-api-crds` on GKE.
  - Bad: flashing images and network boot of Talos hardware stay manual: the provider does not manage hardware.
  - Bad: a Spot-only GKE pool can be preempted or out of stock and leave the cluster with zero nodes.
  - Bad: amended 2026-11-19: `cluster-gke` must set `enableCiliumClusterwideNetworkPolicy: true` at creation for the `network-policy` baseline component; enabling it on an existing cluster restarts `anetd`, with downtime.
- Confidence: high, each distribution is the managed or immutable default of its target.
- Confirmation: `modules/` holds exactly one `cluster-*` module per target; `infra` contains no Ansible code; the `cluster-gke` node pool input accepts Spot and on-demand pools; `cluster-gke` sets `enableCiliumClusterwideNetworkPolicy: true`.
- Revisit when: a cloud other than GKE is needed, or Talos stops supporting the Raspberry Pi models in use.

Source: [RFC 0003](../../docs/rfc/0003-cluster-distribution-per-target.md), reviewed in https://github.com/gsuquet/infra/pull/5.

<!-- readability: allow-code V2 -->
