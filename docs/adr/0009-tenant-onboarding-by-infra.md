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

* the tenant namespaces, carrying the network policy label (ADR-0010) and the Pod Security Admission label
  `pod-security.kubernetes.io/enforce: restricted`;
* an `AppProject`: `sourceRepos` limited to `gsuquet/gitops`, destinations limited to the tenant namespaces, an
  empty `clusterResourceWhitelist` (no cluster-scoped resources), and a `namespaceResourceBlacklist` containing
  `NetworkPolicy` and `CiliumNetworkPolicy`;
* a `ResourceQuota` and a `LimitRange` per namespace;
* the `SecretStore` named `secrets` per namespace (ADR-0016);
* an `Application` pointing at `tenants/<tenant>/<cluster>/` in `gsuquet/gitops`.

### Consequences

* Good, because a tenant cannot escape its namespaces or open network paths: the `AppProject` blocks
  cluster-scoped resources and network policies, and the `restricted` Pod Security Standard rejects privileged,
  `hostNetwork`, `hostPID` and `hostPath` pods, which would otherwise reach the node or sit outside the endpoint
  default deny (ADR-0010).
* Bad, because `restricted` rejects images that run as root or need extra capabilities: tenants must build for it.
  A tenant file may lower its namespaces to `baseline` only through an `infra` pull request; never `privileged`.
* Good, because quotas protect shared hardware such as Raspberry Pis.
* Bad, because tenants cannot add their own network allows: any allow rule needed by a tenant (ingress from a
  Gateway, egress to a database) must be declared by the platform, likely in the tenant file. The format is not
  designed yet.
* Bad, because every new tenant or quota change is an `infra` pull request.
* Risk: the `namespaceResourceBlacklist` does not list `SecretStore`, so a tenant could ship its own store named
  `secrets` and fight the platform-rendered one (ADR-0016). Adding `SecretStore` to the blacklist is pending the
  owner's decision, because it extends the settled blacklist.

### Confirmation

Conftest policies on `rendered/` check each tenant `AppProject` for the source, destination and blacklist rules,
and fail any `Namespace` without a `pod-security.kubernetes.io/enforce` label (except `kube-system`) or any tenant
namespace whose level is `privileged`.

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
