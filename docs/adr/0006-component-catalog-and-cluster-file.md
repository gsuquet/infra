---
adr: 0006
title: Define a component catalog and a cluster.yaml per cluster
status: accepted
date: 2026-11-18
rfc: docs/rfc/0006-component-catalog-and-cluster-file.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0006. Define a component catalog and a cluster.yaml per cluster

- Status: accepted on 2026-11-18 by gsuquet
- Context: several clusters running overlapping components with small differences, facing drift between copies and the need for one view per cluster.
- Decision: we decided for a component catalog `gitops/components/<name>/` (Helm source with a pinned version and default values) and one `gitops/clusters/<name>/cluster.yaml` per cluster (enabled components, per-component value overrides, tenants), merged by the render into `gitops/clusters/<name>/rendered/<component>/`, and against per-cluster copies and Argo CD ApplicationSets with cluster generators, to achieve one definition per component and one reviewable file per cluster, accepting a custom render task and config split between catalog and cluster file.
- Consequences:
  - Good: adding a component to a cluster is one line plus optional overrides.
  - Good: a chart version bump lives in one place and renders into every cluster.
  - Bad: a component's effective config is split between the catalog and each `cluster.yaml`.
  - Bad: the `cluster.yaml` format is a contract that needs a JSON Schema and a check.
- Confidence: high, the same model ran in `homelab`.
- Confirmation: `mise run manifests:render` reads only `gitops/components/`, `gitops/clusters/*/cluster.yaml` and `gitops/tenants/`; a schema check validates every `cluster.yaml`.
- Revisit when: overrides in `cluster.yaml` grow larger than the catalog defaults they override.

Source: [RFC 0006](../../docs/rfc/0006-component-catalog-and-cluster-file.md), reviewed in https://github.com/gsuquet/infra/pull/5.
