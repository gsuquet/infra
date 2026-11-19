---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Keep tenant application code in its own repositories and rendered tenant manifests in gsuquet/gitops

## Context and Problem Statement

Applications (tenants) are developed independently of the platform. Where do their source code and the
manifests deployed per cluster live, and what may a tenant change?

## Decision Drivers

* Platform changes and application releases should not share a review queue.
* Tenant deploys must not be able to change cluster-scoped resources.
* The same rendered manifests pattern as the platform (ADR-0005).

## Considered Options

* App code in own repos; rendered manifests in a separate public repo `gsuquet/gitops`
* Tenant manifests inside `infra`
* Each app repo holds its own deploy manifests

## Decision Outcome

Chosen option: "App code in own repos; rendered manifests in `gsuquet/gitops`".

* Each application has its own repository (code, chart or Kustomize sources).
* Rendered tenant manifests live in `gsuquet/gitops` under `tenants/<tenant>/<cluster>/`.
* `infra` only onboards tenants (ADR-0009); each tenant Argo CD `Application` is restricted to `gsuquet/gitops`.

### Consequences

* Good, because the platform repo does not change on every release.
* Good, because one place lists what every tenant runs on every cluster.
* Bad, because three repositories are involved in a first deploy (app, gitops, infra onboarding).
* Bad, because `gsuquet/gitops` is public: no secret values in it, only `ExternalSecret` references (ADR-0016).

### Confirmation

Every tenant `AppProject` has `sourceRepos` limited to `gsuquet/gitops`.

## Pros and Cons of the Options

### Separate `gsuquet/gitops`

* Good, because clear ownership boundary.
* Bad, because one more repository.

### Tenant manifests inside `infra`

* Good, because one repository.
* Bad, because every release is a platform pull request.

### Manifests in each app repo

* Good, because self-contained apps.
* Bad, because Argo CD must trust many repositories, and there is no single view per cluster.
