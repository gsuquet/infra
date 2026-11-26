---
adr: 0014
title: Install a fixed baseline of components on every cluster
status: accepted
date: 2026-11-18
rfc: docs/rfc/0014-baseline-components.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0014. Install a fixed baseline of components on every cluster

- Status: accepted on 2026-11-18 by gsuquet
- Context: a component catalog shared by clusters of very different sizes, facing tenants that need guaranteed APIs and Raspberry Pis that need a small footprint.
- Decision: we decided for a small fixed baseline on every cluster: `argocd`, `cert-manager`, `external-secrets` and `network-policy` everywhere, GKE included, plus `gateway-api-crds` and `cilium` everywhere except GKE (GKE owns its Gateway API CRDs and dataplane), with every other component (Gateway implementation, `cloudflared`, Kargo, observability, storage, ...) opt-in in `cluster.yaml`, and against a large baseline and no baseline, to achieve APIs and default deny that platform and tenant manifests can always assume, accepting that a cluster serves no route until it enables a Gateway implementation.
- Consequences:
  - Good: platform and tenant manifests can always assume `Gateway` CRDs, `Certificate`, `ExternalSecret`, the `secrets` store and default deny.
  - Good: small clusters stay small.
  - Good: amended 2026-11-19: `network-policy` joins the baseline on every cluster, GKE included, so default deny is a component like the others.
  - Bad: a Gateway implementation is opt-in: a cluster with Gateway API CRDs and no implementation serves no route.
  - Bad: the baseline list is a rule the render or a schema must enforce.
  - Bad: unresolved: tenant onboarding and platform `Namespace` manifests were decided on 2026-11-18 as a render-emitted `rendered/platform/` layer, but the render on `main` has no such layer and passes `gitops.tenants` to a `tenant` component; the owner decides which one renders them.
- Confidence: high, each baseline component is a dependency of other components or of tenants.
- Confirmation: the render, or a schema check on `cluster.yaml`, fails when a baseline component is missing, with the GKE exceptions for `cilium` and `gateway-api-crds`.
- Revisit when: a component becomes a dependency of most tenants (for example metrics), or the baseline no longer fits a Raspberry Pi cluster.

Source: [RFC 0014](../../docs/rfc/0014-baseline-components.md), reviewed in https://github.com/gsuquet/infra/pull/5.
