---
adr: 0017
title: Organise infra by landing zones, modules, clusters, gitops
status: accepted
date: 2026-11-18
rfc: docs/rfc/0017-repository-layout.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0017. Organise infra by landing zones, modules, clusters, gitops

- Status: accepted on 2026-11-18 by gsuquet
- Decision: In the context of one repository holding account foundations, cluster IaC and GitOps sources, facing files with no obvious place, we decided for four top-level areas: `landing-zone/{cloudflare,gcp}/` (account foundation roots), `modules/` (every child module: `cluster-*`, `bootstrap-*`, `cloudflare-domain`, ...), `clusters/<name>/` (one IaC root per cluster) and `gitops/` (`components/<name>/`, `clusters/<name>/` with `cluster.yaml` and `rendered/`, `tenants/<tenant>.yaml`), with a cluster named the same in `clusters/<name>/` and `gitops/clusters/<name>/`, and against child modules nested in their root and one root for everything, to achieve one obvious place per file and reusable child modules, accepting that a module used by one root lives away from it.
- Consequences:
  - Good: removing a cluster removes two folders with the same name.
  - Good: every child module is reusable by any root.
  - Bad: a module used by one root still lives away from it.
- Confidence: high, it follows the HashiCorp standard module structure.
- Confirmation: no `modules/` folder below a root module; each folder has a README describing what belongs there.
- Revisit when: a root needs a child module that no other root can reuse and the indirection costs more than it saves.

Source: [RFC 0017](../../docs/rfc/0017-repository-layout.md), reviewed in https://github.com/gsuquet/infra/pull/5.
