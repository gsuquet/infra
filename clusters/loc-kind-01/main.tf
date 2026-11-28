# The cluster only: mise run cluster:up then hands it over to Argo CD
# (cluster:bootstrap). No in-cluster object lives in this state.
module "cluster" {
  source = "../../modules/cluster-kind"

  name            = local.name
  kubeconfig_path = "${path.module}/kubeconfig"
  # Same minor as kubernetesVersion in gitops/clusters/loc-kind-01/cluster.yaml.
  node_image = "kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"
}
