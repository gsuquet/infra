---
adr: 0009
title: Onboard tenants from infra with tenant files
status: accepted
date: 2026-11-18
rfc: docs/rfc/0009-tenant-onboarding-by-infra.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0009. Onboard tenants from infra with tenant files

- Status: accepted on 2026-11-18 by gsuquet
- Decision: In the context of onboarding tenants onto shared clusters, facing tenants escaping their namespaces or opening network paths, we decided for `gitops/tenants/<tenant>.yaml` plus a tenant list in each `cluster.yaml`, rendered by `infra` into, per tenant: namespaces with the network policy label and `pod-security.kubernetes.io/enforce: restricted` (lowered to `baseline` only through an `infra` pull request, never `privileged`); an `AppProject` with `sourceRepos` only `gsuquet/gitops`, destinations only the tenant namespaces, an empty `clusterResourceWhitelist` and `NetworkPolicy` and `CiliumNetworkPolicy` in `namespaceResourceBlacklist`; a `ResourceQuota` and a `LimitRange` per namespace; the `SecretStore` `secrets` per namespace; and an `Application` on `tenants/<tenant>/<cluster>/` in `gsuquet/gitops`, and against tenant-created namespaces and a self-service operator, to achieve isolation from one reviewed template, accepting an `infra` pull request for every tenant change.
- Consequences:
  - Good: a tenant cannot create cluster-scoped resources or network policies, and `restricted` rejects privileged, `hostNetwork`, `hostPID` and `hostPath` pods that would reach the node or sit outside the endpoint default deny.
  - Good: quotas protect shared hardware such as Raspberry Pis.
  - Bad: `restricted` rejects images that run as root or need extra capabilities: tenants build for it.
  - Bad: tenants cannot add network allows: the platform declares them, likely in the tenant file, in a format not designed yet.
  - Bad: every new tenant or quota change is an `infra` pull request.
  - Bad: `SecretStore` is not in the blacklist: a tenant could ship a store named `secrets` and fight the platform one; the fix waits for the owner's decision.
- Confidence: high, isolation relies on Argo CD project limits and Pod Security Admission, both enforced by the cluster.
- Confirmation: Conftest policies on `rendered/` check each tenant `AppProject` for the source, destination and blacklist rules (on `main`); still to add: a rule that fails any `Namespace` without a `pod-security.kubernetes.io/enforce` label (except `kube-system`) or any tenant namespace at `privileged`.
- Revisit when: the number of tenants makes `infra` pull requests a bottleneck, or a tenant needs its own network allows.

Source: [RFC 0009](../../docs/rfc/0009-tenant-onboarding-by-infra.md), reviewed in https://github.com/gsuquet/infra/pull/5.
