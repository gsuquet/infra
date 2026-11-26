# Tenants

One file per tenant, `gitops/tenants/<tenant>.yaml`. A cluster runs a tenant when its `cluster.yaml` lists it. The
render then produces, per cluster:

* the tenant namespaces, with the network policy label and
  `pod-security.kubernetes.io/enforce: restricted` (`baseline` at most by exception, never `privileged`);
* an `AppProject` limited to `gsuquet/gitops` and the tenant namespaces, with no cluster-scoped resources and no
  `NetworkPolicy` or `CiliumNetworkPolicy`;
* a `ResourceQuota` and a `LimitRange`;
* the External Secrets `SecretStore` named `secrets` per namespace;
* an `Application` syncing `tenants/<tenant>/<cluster>/` from `gsuquet/gitops`.

Tenant application code and rendered tenant manifests do not live here.
