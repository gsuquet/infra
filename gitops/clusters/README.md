# Clusters (GitOps)

One folder per cluster, `gitops/clusters/<name>/`, with the same name as its Terraform root in
[`clusters/`](../../clusters/):

* `cluster.yaml`: enabled components, per-component value overrides, and the tenants of the cluster.
* `rendered/<component>/`: plain manifests written by `mise run manifests:render`. Do not edit them by hand;
  `mise run manifests:check` fails on any drift
  ([ADR-0005](../../docs/adr/0005-rendered-manifests-pattern.md)).

The cluster's own Argo CD applies `rendered/` as plain YAML, with sync waves: CRDs `-1`, Applications `1` and
higher ([ADR-0004](../../docs/adr/0004-self-managed-argo-cd-per-cluster.md)).
