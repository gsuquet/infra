---
rfc: 0003
title: Use kind, Talos and GKE as distributions per target
status: accepted
track: full
reversibility: one-way
author: gsuquet
deciders: gsuquet
created: 2026-11-18
updated: 2026-11-19
review: https://github.com/gsuquet/infra/pull/5
adr: docs/adr/0003-cluster-distribution-per-target.md
supersedes: null
superseded-by: null
---

# RFC 0003: Use kind, Talos and GKE as distributions per target

<!-- readability: allow-code V2 -->

## Summary

Each target gets one Kubernetes distribution and one child module: kind on developer machines, Talos Linux on
Raspberry Pis and local servers, GKE in the cloud. Everything is provisioned by IaC, with no Ansible. Amended
on 2026-11-19: `cluster-gke` takes Spot pools, on-demand pools or both, per cluster.

| Decision | Why | Cost | Reversible |
| --- | --- | --- | --- |
| Run kind on developer machines, Talos on owned hardware and GKE in the cloud, with one `cluster-*` module each | The most operable option per target, with no Ansible | Three code paths that differ in CNI, storage and load balancing | no, before a cluster holds data, destroy and recreate it; once it holds data, changing distribution needs a data migration and downtime |
| Let each GKE cluster choose Spot pools, on-demand pools or both | Spot cuts the bill but can leave zero nodes | A Spot-only cluster can lose every node | yes, by input, with no module change |
| Create every GKE cluster with Dataplane V2 and `enableCiliumClusterwideNetworkPolicy: true` | The `network-policy` component needs the CRD | Enabling the flag on an existing cluster restarts `anetd`, with downtime | not stated, see the [open point](https://github.com/gsuquet/infra/pull/18) |

## Context

- The platform runs on three kinds of targets: developer machines, owned hardware (Raspberry Pis, local
  servers) and a cloud.
- `homelab` used k3s installed by Ansible: mutable, SSH-based, outside the IaC plan.
- The same GitOps catalog must run on every target.
- GKE Spot VMs cut the cloud bill but can be preempted or out of stock, which can leave a cluster with zero
  nodes, Argo CD included (GKE study, pull request #7).

## Goals and non-goals

Goals:

- One distribution and one `cluster-*` module per target.
- No Ansible and no SSH configuration anywhere.
- Each GKE cluster chooses its node pool mix (Spot, on-demand, both) by input.

Non-goals:

- Clouds other than GKE (AWS, Azure, ...).
- Hardware provisioning: flashing images and network boot.

## Decision drivers

- Everything is provisioned by IaC; no Ansible.
- The same GitOps catalog runs on every target.
- Owned hardware is immutable and API-driven.
- The cloud is managed: no control plane to operate.

## Options considered

### kind, Talos and GKE

kind on developer machines, Talos on hardware, GKE in the cloud.

- Good: the most operable option per target (immutable hardware, managed cloud).
- Bad: three code paths to maintain (same catalog everywhere).

### k3s everywhere, installed by Ansible

The `homelab` model.

- Good: one distribution (same catalog).
- Bad: mutable SSH configuration outside the IaC plan (no Ansible).

### kind, kubeadm and self-managed cloud VMs

- Good: upstream Kubernetes everywhere (same catalog).
- Bad: a full OS and control plane to patch on every node (managed cloud, immutable hardware).

### Do nothing

Keep `olympus` on k3s and Ansible, no cloud and no local cluster.

- Good: no work.
- Bad: no disposable local cluster and no cloud target.

## Proposal

```mermaid
flowchart LR
    C["GitOps catalog"] --> K["kind: developer machine"]
    C --> T["Talos Linux: Raspberry Pi, local server"]
    C --> G["GKE: cloud"]
    K -.- MK["cluster-kind: a kind provider"]
    T -.- MT["cluster-talos: siderolabs/talos"]
    G -.- MG["cluster-gke: hashicorp/google"]
    MG --> P["node pools: Spot, on-demand or both"]
```

One catalog, three targets, one child module each.

| Target | Distribution | Provider | Note |
| --- | --- | --- | --- |
| Developer machine | kind | a kind provider, chosen in `cluster-kind` | disposable |
| Raspberry Pi, local server | Talos Linux | `siderolabs/talos` | API only: machine configs rendered by IaC, no SSH |
| Cloud | GKE, managed | `hashicorp/google` | Dataplane V2 with `enableCiliumClusterwideNetworkPolicy: true` always set at creation (RFC 0010; enabling it later restarts `anetd`, with downtime); skips `cilium` and `gateway-api-crds` |

`cluster-gke` node pools come from an input list: each pool sets Spot or on-demand, so a cluster runs Spot
only, on-demand only, or both (for example one on-demand node for the baseline and a Spot pool for tenants).

## Operational impact

- Blast radius: every cluster: a distribution change rebuilds the cluster and moves its workloads.
- Rollout: kind first (disposable), then Talos, then GKE; each cluster root is created separately.
- Rollback: before a cluster holds data, destroy and recreate it; once it holds data, changing distribution needs a data migration and downtime.
- Migration: None: no cluster exists yet; `olympus` moves later through the cut-over RFC (RFC 0002).
- Security: Talos removes SSH from owned hardware; GKE credentials stay local to the cluster root, never in CI.
- Cost: kind and Talos run on owned hardware; GKE cost depends on the node pool mix, Spot being the cheapest (figures in RFC 0024).
- Observability: each cluster reports Argo CD sync and health; on GKE, node pool preemption shows as nodes leaving the cluster.

## Drawbacks and risks

| Risk | Severity (proposed) | Mitigation |
| --- | --- | --- |
| A Spot-only GKE cluster can lose every node at once, Argo CD included | high | pick on-demand pools, or both, where outages are not accepted. |
| The `network-policy` component needs the `CiliumClusterwideNetworkPolicy` CRD, which GKE adds only when the cluster sets `enableCiliumClusterwideNetworkPolicy: true`; enabling it on an existing cluster restarts `anetd`, with downtime | high | `cluster-gke` always sets it at creation. |
| The `siderolabs/talos` provider does not manage the hardware | medium | flashing images and network boot stay manual steps. |
| Three distributions differ in CNI, storage and load balancing | low | the catalog handles the differences per cluster (RFC 0011). |
| GKE owns its dataplane (RFC 0011) and, with its Gateway API enabled (always on Autopilot), the Gateway API CRDs (RFC 0012) | low | the catalog skips `cilium` and `gateway-api-crds` on GKE. |

## Open questions

None.

## Decision

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

## Implementation

N/A: no `cluster-*` module exists yet.

## References

- [Talos Terraform provider](https://registry.terraform.io/providers/siderolabs/talos/latest/docs)
- [Talos documentation](https://docs.siderolabs.com/)
- RFC 0022: IaC tool (https://github.com/gsuquet/infra/pull/11)
- RFC 0024: GKE (https://github.com/gsuquet/infra/pull/7)
- RFC 0025: Talos on Raspberry Pi (https://github.com/gsuquet/infra/pull/9)
- [GKE: configure CiliumClusterwideNetworkPolicy](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/configure-cilium-network-policy)

## Future work

- Clouds other than GKE (AWS, Azure, ...): out of scope.
