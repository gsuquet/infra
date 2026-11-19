# Tenants

One file per tenant, `gitops/tenants/<tenant>.yaml`; a cluster runs the tenant when its `cluster.yaml` lists it. Tenant code and rendered tenant manifests live elsewhere (`gsuquet/gitops`).
To add one: [How to onboard a tenant](../../docs/how-to/onboard-a-tenant.md); what a tenant can do: [Tenant isolation](../../docs/concepts/tenant-isolation.md).
