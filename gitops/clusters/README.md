# Clusters (GitOps)

One folder per cluster, `gitops/clusters/<name>/`, with the same name as its Terraform root in
[`clusters/`](../../clusters/):

* `cluster.yaml`: enabled components, per-component value overrides, and the tenants of the cluster.
* `rendered/platform/`: the cluster layer the render emits for every cluster, not a catalog component: platform
  `Namespace` manifests, tenant onboarding and the default-deny network policy. `platform` is reserved as a component
  name.
* `rendered/<component>/`: plain manifests written by `mise run manifests:render`. Do not edit them by hand;
  `mise run manifests:check` fails on any drift.

The cluster's own Argo CD applies `rendered/` as plain YAML, with sync waves: CRDs `-1`, Applications `1` and higher.
