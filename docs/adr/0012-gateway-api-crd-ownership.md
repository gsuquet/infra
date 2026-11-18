---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Use Gateway API with one component owning its CRDs and swappable implementations

## Context and Problem Statement

North-south traffic uses Gateway API. Several implementations exist (Cilium, Envoy Gateway, agentgateway, ...),
and many charts bundle their own copy of the Gateway API CRDs. Two owners of the same CRDs fight on version and
on Argo CD sync. Who owns the CRDs, and how are implementations chosen?

## Decision Drivers

* One owner and one version of each CRD per cluster.
* An implementation can be replaced or added without touching the CRDs.
* Cilium's Gateway API support requires the CRDs to exist before the Cilium operator starts.

## Considered Options

* Dedicated `gateway-api-crds` component; implementations installed without bundled CRDs, one `GatewayClass` each
* Let the chosen implementation install the CRDs
* Ingress API instead of Gateway API

## Decision Outcome

Chosen option: "Dedicated `gateway-api-crds` component".

* `gateway-api-crds` renders the upstream Gateway API CRDs at one pinned version; it is a baseline component.
* Every implementation is installed with its CRD installation disabled, and owns exactly one `GatewayClass`.
* Implementations are swappable per cluster in `cluster.yaml`; more than one can coexist.

### Consequences

* Good, because CRD upgrades are a single, explicit pull request.
* Good, because switching implementation does not delete CRDs and the routes using them.
* Bad, because every implementation's supported Gateway API version must be checked against the pinned CRDs on
  upgrade.
* Bad, because the CRDs are installed by Terraform at bootstrap before Cilium (ADR-0015), then adopted by Argo CD.
* Deferred: which implementation is the default per cluster; experimental-channel CRDs (e.g. `TLSRoute`).

### Confirmation

A Conftest policy fails any Gateway API `CustomResourceDefinition` rendered outside `rendered/gateway-api-crds/`.

## Pros and Cons of the Options

### Dedicated CRD component

* Good, because single ownership.
* Bad, because chart options to disable bundled CRDs must exist for each implementation.

### Implementation installs the CRDs

* Good, because simplest for one implementation.
* Bad, because two implementations conflict.

### Ingress API

* Good, because universal.
* Bad, because frozen API with annotation-based extensions.

## More Information

* [Gateway API](https://gateway-api.sigs.k8s.io/)
* [Cilium Gateway API support](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)
