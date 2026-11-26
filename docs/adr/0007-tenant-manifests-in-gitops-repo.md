---
adr: 0007
title: Keep tenant manifests in gsuquet/gitops, code in app repos
status: accepted
date: 2026-11-18
rfc: docs/rfc/0007-tenant-manifests-in-gitops-repo.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0007. Keep tenant manifests in gsuquet/gitops, code in app repos

- Status: accepted on 2026-11-18 by gsuquet
- Context: tenant applications developed independently of the platform, facing shared review queues and tenant access to cluster-scoped resources.
- Decision: we decided for application code in its own repositories and rendered tenant manifests in the public repository `gsuquet/gitops` under `tenants/<tenant>/<cluster>/` (no secret value, only `ExternalSecret` references), with `infra` only onboarding tenants and restricting each tenant `AppProject` to `gsuquet/gitops`, and against tenant manifests inside `infra` and manifests in each app repository, to achieve separate review queues and one view of every tenant per cluster, accepting three repositories in a first deploy.
- Consequences:
  - Good: the platform repository does not change on every release.
  - Good: one place lists what every tenant runs on every cluster.
  - Bad: three repositories are involved in a first deploy (app, `gsuquet/gitops`, `infra` onboarding).
  - Bad: `gsuquet/gitops` is public: it never holds a secret value.
- Confidence: high, the boundary matches the ownership of each repository.
- Confirmation: every tenant `AppProject` has `sourceRepos` limited to `gsuquet/gitops` (Conftest policy on `rendered/`).
- Revisit when: tenants need manifests that `gsuquet/gitops` cannot hold publicly.

Source: [RFC 0007](../../docs/rfc/0007-tenant-manifests-in-gitops-repo.md), reviewed in https://github.com/gsuquet/infra/pull/5.
