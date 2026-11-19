# Clusters

One Terraform root per cluster, `clusters/<name>/`, calling only `cluster-*` and `bootstrap-*` modules; Argo CD then syncs [`gitops/clusters/<name>/`](../gitops/clusters/README.md), same name.
How a cluster is created and handed to Argo CD: [Cluster lifecycle](../docs/concepts/cluster-lifecycle.md).
