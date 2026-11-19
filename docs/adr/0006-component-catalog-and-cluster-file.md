---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Define components in a catalog and enable them per cluster in cluster.yaml

## Context and Problem Statement

Several clusters run overlapping sets of components with small differences (CNI, storage, domains). Where is a
component defined, and where does a cluster say which components it runs and with which values?

## Decision Drivers

* One definition per component, reused by every cluster.
* One file per cluster that tells what runs on it.
* Overrides close to the cluster, visible in review.

## Considered Options

* Component catalog + `cluster.yaml` per cluster
* Per-cluster copies of each component
* Argo CD ApplicationSets with cluster generators

## Decision Outcome

Chosen option: "Component catalog + `cluster.yaml` per cluster".

* `gitops/components/<name>/` holds the Helm source (chart reference, pinned version) and the default values.
* `gitops/clusters/<name>/cluster.yaml` lists the enabled components, per-component value overrides, and the
  tenants of the cluster (ADR-0009).
* The render merges defaults and overrides and writes `gitops/clusters/<name>/rendered/<component>/`.

### Consequences

* Good, because adding a component to a cluster is one line plus optional overrides.
* Good, because a chart version bump lives in one place and renders into every cluster.
* Bad, because a component's effective config is split between the catalog and each `cluster.yaml`.
* Bad, because the `cluster.yaml` format is a contract: it needs a JSON Schema and a check (to be added with the
  render task).

### Confirmation

`mise run manifests:render` reads only `gitops/components/` and `gitops/clusters/*/cluster.yaml`; a schema check
validates every `cluster.yaml`.

## Pros and Cons of the Options

### Component catalog + `cluster.yaml`

* Good, because explicit and reviewable.
* Bad, because a custom render task to maintain.

### Per-cluster copies

* Good, because no indirection.
* Bad, because copies drift and every upgrade touches every cluster by hand.

### ApplicationSets with cluster generators

* Good, because native Argo CD.
* Bad, because rendering moves back to sync time, against ADR-0005.
