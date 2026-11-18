---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Organise the repository by landing zones, modules, cluster roots and gitops

## Context and Problem Statement

`infra` holds Terraform for account-level foundations, Terraform for clusters, and GitOps sources. Each new file
needs one obvious place.

## Decision Drivers

* Terraform root modules (with state) are separated from child modules (without state).
* All files of one cluster are found by its name.
* Follows the HashiCorp standard module structure.

## Considered Options

* `landing-zone/`, `modules/`, `clusters/`, `gitops/`
* Child modules nested inside their root (current `landing-zone/cloudflare/modules/domain`)
* One root module for everything

## Decision Outcome

Chosen option: "`landing-zone/`, `modules/`, `clusters/`, `gitops/`".

```text
landing-zone/{cloudflare,gcp}/   Terraform roots for account foundations
modules/                         every child module: cluster-*, bootstrap-*, cloudflare-domain, ...
clusters/<name>/                 one Terraform root per cluster
gitops/components/<name>/        catalog: Helm source and default values
gitops/clusters/<name>/          cluster.yaml and rendered/<component>/
gitops/tenants/<tenant>.yaml     tenant onboarding
docs/adr/                        decisions
```

A cluster's name is the same in `clusters/<name>/` and `gitops/clusters/<name>/`.

### Consequences

* Good, because removing a cluster removes two folders with the same name.
* Good, because every child module is reusable by any root.
* Bad, because a module used by one root still lives away from it (the Cloudflare `domain` module moves to
  `modules/cloudflare-domain`).
* Deferred: `landing-zone/gcp/` content (projects, IAM, network for GKE).

### Confirmation

No `modules/` folder below a root module; each folder has a README describing what belongs there.

## Pros and Cons of the Options

### Four top-level areas

* Good, because one place per kind of file.
* Bad, because more top-level folders.

### Nested child modules

* Good, because locality.
* Bad, because reuse across roots needs relative paths across trees.

### One root

* Good, because simple.
* Bad, because one state and one blast radius for everything.
