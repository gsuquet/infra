---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Onboard tenants from infra with a tenant file and a per-cluster tenant list

## Context and Problem Statement

A tenant needs namespaces, permissions, quotas and an Argo CD `Application` on each cluster where it runs. Who
creates them, and what may the tenant do itself?

## Decision Drivers

* The platform owns cluster-scoped resources and isolation; tenants own only their workloads.
* Onboarding must be declarative and reviewed.

## Considered Options

* `gitops/tenants/<tenant>.yaml` + tenant list in `cluster.yaml`, rendered by `infra`
* Tenants create their own namespaces and projects
* A self-service operator

## Decision Outcome

Chosen option: "`gitops/tenants/<tenant>.yaml` + tenant list in `cluster.yaml`". For each tenant listed by a
cluster, the render produces:

* the tenant namespaces, carrying the network policy label (ADR-0010);
* an `AppProject`: `sourceRepos` limited to `gsuquet/gitops`, destinations limited to the tenant namespaces, an
  empty `clusterResourceWhitelist` (no cluster-scoped resources), and a `namespaceResourceBlacklist` containing
  `NetworkPolicy` and `CiliumNetworkPolicy`;
* a `ResourceQuota` and a `LimitRange` per namespace;
* the `SecretStore` named `secrets` per namespace (ADR-0016);
* an `Application` pointing at `tenants/<tenant>/<cluster>/` in `gsuquet/gitops`.

### Consequences

* Good, because a tenant cannot escape its namespaces or open network paths.
* Good, because quotas protect shared hardware such as Raspberry Pis.
* Bad, because tenants cannot add their own network allows: any allow rule needed by a tenant (ingress from a
  Gateway, egress to a database) must be declared by the platform, likely in the tenant file. The format is not
  designed yet.
* Bad, because every new tenant or quota change is an `infra` pull request.

### Confirmation

Conftest policies on `rendered/` check each tenant `AppProject` for the source, destination and blacklist rules.

## Pros and Cons of the Options

### Tenant file + cluster list

* Good, because all isolation rules come from one template.
* Bad, because the platform owner is in the loop for every tenant change.

### Tenant self-service namespaces

* Good, because fast.
* Bad, because tenants would need cluster-scoped permissions.

### Self-service operator

* Good, because scalable.
* Bad, because one more controller to build and run for a small number of tenants.
