# Tenants

One file per tenant, `gitops/tenants/<tenant>.yaml`. A cluster runs a tenant when its `cluster.yaml` lists it
([ADR-0009](../../docs/adr/0009-tenant-onboarding-by-infra.md)). The render then produces, per cluster:

* the tenant namespaces, with the network policy label
  ([ADR-0010](../../docs/adr/0010-cluster-owned-default-deny-network-policy.md));
* an `AppProject` limited to `gsuquet/gitops` and the tenant namespaces, with no cluster-scoped resources and no
  `NetworkPolicy` or `CiliumNetworkPolicy`;
* a `ResourceQuota` and a `LimitRange`;
* the External Secrets store `secrets` ([ADR-0016](../../docs/adr/0016-secret-store-named-secrets.md));
* an `Application` syncing `tenants/<tenant>/<cluster>/` from `gsuquet/gitops`.

Tenant application code and rendered tenant manifests do not live here
([ADR-0007](../../docs/adr/0007-tenant-manifests-in-gitops-repo.md)).
