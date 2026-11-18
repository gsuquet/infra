# Clusters

One Terraform root module per cluster, in `clusters/<name>/`. It calls a `cluster-*` module and the `bootstrap-*`
modules, nothing else ([ADR-0015](../docs/adr/0015-bootstrap-boundary.md)). Argo CD on the cluster then syncs
[`gitops/clusters/<name>/`](../gitops/clusters/): the name is the same in both places.

State ([ADR-0018](../docs/adr/0018-terraform-state-backends.md)):

* kind clusters: local state, no remote backend.
* Talos and GKE clusters: R2 bucket `terraform-state`, key `clusters/<name>/terraform.tfstate`.

Lifecycle: `mise run cluster:up|plan|down <name>` ([ADR-0019](../docs/adr/0019-lifecycle-tasks-and-ci-scope.md)).
