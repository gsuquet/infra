---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Install a fixed set of baseline components on every cluster

## Context and Problem Statement

The catalog (ADR-0006) can hold many components. Some are needed by everything else (CRDs, CNI, GitOps,
certificates, secrets). Which components does every cluster run, and how are the others chosen?

## Decision Drivers

* Other components and tenants can rely on baseline APIs (`Gateway`, `Certificate`, `ExternalSecret`).
* Small clusters (Raspberry Pis) should run only what they need.

## Considered Options

* Small fixed baseline, everything else opt-in
* Large baseline (observability, ingress, policy engine, ...) on every cluster
* No baseline: each cluster lists everything

## Decision Outcome

Chosen option: "Small fixed baseline, everything else opt-in".

| Component | Every cluster | Note |
| --- | --- | --- |
| `gateway-api-crds` | yes, except GKE (GKE owns the CRDs) | ADR-0012 |
| `cilium` | yes, except GKE | ADR-0011 |
| `argocd` | yes | ADR-0004 |
| `cert-manager` | yes | |
| `external-secrets` | yes | ADR-0016 |

Every other component (Gateway implementation, `cloudflared`, Kargo, observability, storage, ...) is opt-in in
`cluster.yaml`.

### Consequences

* Good, because platform and tenant manifests can always assume these APIs.
* Good, because small clusters stay small.
* Bad, because a Gateway implementation is opt-in: a cluster with Gateway API CRDs but no implementation serves no
  route.
* Bad, because the baseline list is a rule the render or a schema must enforce.
* Note: the default-deny network policy and tenant onboarding are not catalog components; the render emits them
  for every cluster in `rendered/platform/` (ADR-0010).

### Confirmation

The render task, or a schema check on `cluster.yaml`, fails when a baseline component is missing (with the GKE
exceptions for `cilium` and `gateway-api-crds`).

## Pros and Cons of the Options

### Small baseline

* Good, because predictable and light.
* Bad, because useful defaults (metrics) must be enabled per cluster.

### Large baseline

* Good, because uniform clusters.
* Bad, because too heavy for Raspberry Pis.

### No baseline

* Good, because full freedom.
* Bad, because nothing can be assumed by tenants.
