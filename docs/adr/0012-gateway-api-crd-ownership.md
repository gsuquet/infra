---
adr: 0012
title: Give Gateway API CRDs one owner per cluster
status: accepted
date: 2026-11-18
rfc: docs/rfc/0012-gateway-api-crd-ownership.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0012. Give Gateway API CRDs one owner per cluster

- Status: accepted on 2026-11-18 by gsuquet
- Context: Gateway API for north-south traffic with several possible implementations, facing charts that bundle and fight over the same CRDs.
- Decision: we decided for one CRD owner per cluster: the baseline `gateway-api-crds` component on kind and Talos (upstream standard-channel CRDs at one pinned version, including every CRD the enabled implementations need, for Cilium `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `BackendTLSPolicy`, `ReferenceGrant` and `TLSRoute`) and GKE itself on GKE (`gateway-api-crds` skipped, `bootstrap-gateway-api` not called), with every implementation installed with CRD installation disabled, owning exactly one `GatewayClass`, chosen per cluster in `cluster.yaml` and allowed to coexist, and against implementation-installed CRDs and the Ingress API, to achieve one CRD version per cluster and swappable implementations, accepting a version check per implementation on every CRD upgrade.
- Consequences:
  - Good: CRD upgrades are one explicit pull request; switching implementation keeps the CRDs and the routes.
  - Bad: each implementation's supported Gateway API version is checked against the pinned CRDs on upgrade.
  - Bad: the CRDs are installed by IaC at bootstrap before Cilium, then adopted by Argo CD.
  - Bad: on GKE the CRD version follows Google's schedule, not the pin.
  - Bad: deferred: the default implementation per cluster, and experimental-channel CRDs (`TCPRoute`, `UDPRoute`).
  - Bad: Cilium creates a `LoadBalancer` `Service` per `Gateway` and kind and Talos have no provider: Cilium LB-IPAM with L2 announcements (LAN addresses) or Gateway API host network mode, chosen in the `cilium` component; public traffic still enters only through Cloudflare Tunnel.
- Confidence: high, single CRD ownership is the documented way to run several implementations.
- Confirmation: a Conftest policy fails any Gateway API `CustomResourceDefinition` rendered outside `rendered/gateway-api-crds/`, and any GKE cluster that renders `gateway-api-crds`.
- Revisit when: an implementation needs experimental-channel CRDs, or GKE stops managing the CRDs.

Source: [RFC 0012](../../docs/rfc/0012-gateway-api-crd-ownership.md), reviewed in https://github.com/gsuquet/infra/pull/5.

<!-- readability: allow-code L2 -->
