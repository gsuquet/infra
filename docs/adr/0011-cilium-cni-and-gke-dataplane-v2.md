---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Use Cilium with kube-proxy replacement on kind and Talos, and Dataplane V2 on GKE

## Context and Problem Statement

Each distribution ships a default CNI (kindnet on kind, Flannel on Talos, GKE's own dataplane). The network
policy model (ADR-0010) and Gateway API (ADR-0012) need a capable dataplane. Which CNI does each target use?

## Decision Drivers

* Same CNI and policy semantics on kind and Talos, so local tests match the hardware clusters.
* No CNI to operate on the managed cloud.
* eBPF kube-proxy replacement to drop kube-proxy.

## Considered Options

* Cilium on kind and Talos, GKE Dataplane V2 on GKE
* Cilium everywhere, including a self-installed Cilium on GKE
* Distribution default CNIs

## Decision Outcome

Chosen option: "Cilium on kind and Talos, GKE Dataplane V2 on GKE".

* kind: default CNI disabled and kube-proxy disabled in the kind config; Cilium installed by the bootstrap.
* Talos: default Flannel CNI and kube-proxy disabled in the machine config; Cilium with
  `kubeProxyReplacement=true`, pointed at KubePrism (`localhost:7445`), with Talos-specific cgroup settings.
* GKE: Dataplane V2 enabled at cluster creation; the catalog skips the `cilium` component on GKE clusters.

### Consequences

* Good, because kind reproduces the Talos dataplane.
* Good, because GKE needs no CNI upgrades from this repository.
* Bad, because a Talos or kind node stays `NotReady` until Cilium runs: Cilium must be installed by Terraform
  before Argo CD (ADR-0015).
* Bad, because GKE Dataplane V2 is a managed Cilium with a restricted feature set; Cilium-specific features
  (and possibly `CiliumClusterwideNetworkPolicy`, see ADR-0010) may differ on GKE. Not verified.
* Bad, because the Talos machine config patch differs by Talos version (`cluster.network.cni.name: none` and
  `cluster.proxy.disabled: true` before Talos 1.14, separate config documents from 1.14).

### Confirmation

`cluster.yaml` of every GKE cluster omits `cilium`; every kind and Talos cluster lists it. A schema or policy
check enforces this once `cluster.yaml` has a `distribution` field.

## Pros and Cons of the Options

### Cilium on kind and Talos, Dataplane V2 on GKE

* Good, because best fit per target.
* Bad, because two dataplanes to reason about.

### Cilium everywhere

* Good, because one dataplane.
* Bad, because self-installed Cilium on GKE is unsupported by Google and must be maintained here.

### Distribution defaults

* Good, because nothing to install.
* Bad, because the default CNIs support neither `CiliumClusterwideNetworkPolicy` nor kube-proxy replacement, and
  kindnet differs from the Talos dataplane.

## More Information

* [Deploying Cilium on Talos](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)
* [Cilium kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
