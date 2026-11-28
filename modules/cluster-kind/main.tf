resource "kind_cluster" "this" {
  name            = var.name
  node_image      = var.node_image
  kubeconfig_path = var.kubeconfig_path
  # Without a CNI the node never gets Ready: the bootstrap waits for it after
  # it installs Cilium instead.
  wait_for_ready = !var.disable_default_cni

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
    }

    networking {
      disable_default_cni = var.disable_default_cni
      kube_proxy_mode     = var.disable_default_cni ? "none" : "iptables"
    }
  }
}
