---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Use kind, Talos and GKE as cluster distributions per target

## Context and Problem Statement

The platform runs on three kinds of targets: developer machines, owned hardware (Raspberry Pis and local servers)
and a cloud. Which Kubernetes distribution and provisioning tool does each target use?

## Decision Drivers

* Everything is provisioned by Terraform; no Ansible.
* The same GitOps catalog must run on every target.
* Owned hardware should be immutable and API-driven.
* Cloud should be managed: no control plane to operate.

## Considered Options

* kind (dev) + Talos (hardware) + GKE (cloud)
* k3s everywhere, installed by Ansible (the `homelab` model)
* kind (dev) + kubeadm (hardware) + self-managed cloud VMs

## Decision Outcome

Chosen option: "kind (dev) + Talos (hardware) + GKE (cloud)".

| Target | Distribution | Terraform provider |
| --- | --- | --- |
| Developer machine | kind | a kind provider (choice in the `cluster-kind` module) |
| Raspberry Pi, local server | Talos Linux | `siderolabs/talos` |
| Cloud | GKE (managed) | `hashicorp/google` |

Each target has one child module: `cluster-kind`, `cluster-talos`, `cluster-gke`.

### Consequences

* Good, because Talos is configured only through its API: machine configs are Terraform-rendered, no SSH, no Ansible.
* Good, because GKE removes control plane operations for the cloud.
* Good, because kind gives a disposable cluster to test the same catalog locally.
* Bad, because three distributions differ in CNI, storage and load balancing; the catalog must handle these
  differences per cluster (see ADR-0011).
* Bad, because GKE owns some in-cluster pieces itself: its dataplane (ADR-0011) and, with its Gateway API
  enabled (always on Autopilot), the Gateway API CRDs (ADR-0012). The catalog skips `cilium` and
  `gateway-api-crds` on GKE.
* Bad, because the `siderolabs/talos` provider does not manage the hardware itself: flashing images and network
  boot remain manual steps.
* Deferred: non-GKE clouds (AWS, Azure, ...) are out of scope.

### Confirmation

`modules/` holds exactly one `cluster-*` module per target; `infra` contains no Ansible code.

## Pros and Cons of the Options

### kind (dev) + Talos (hardware) + GKE (cloud)

* Good, because each target uses the most operable option for its context.
* Bad, because three code paths to maintain.

### k3s everywhere, installed by Ansible

* Good, because one distribution.
* Bad, because Ansible is mutable, SSH-based configuration, outside the Terraform plan.

### kind (dev) + kubeadm (hardware) + self-managed cloud VMs

* Good, because upstream Kubernetes everywhere.
* Bad, because a full OS and control plane to patch on every node.

## More Information

* [Talos Terraform provider](https://registry.terraform.io/providers/siderolabs/talos/latest/docs)
* [Talos documentation](https://docs.siderolabs.com/)
