# Clusters

One Terraform root module per cluster, in `clusters/<name>/`. It calls a `cluster-*` module and the `bootstrap-*`
modules, nothing else. Argo CD on the cluster then syncs
[`gitops/clusters/<name>/`](../gitops/clusters/): the name is the same in both places.

State:

* kind clusters: local state, no remote backend.
* Talos and GKE clusters: R2 bucket `terraform-state`, key `clusters/<name>/terraform.tfstate`.

Lifecycle: `mise run cluster:up|plan|down <name>` (planned).
