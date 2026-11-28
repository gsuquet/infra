variable "name" {
  description = "Cluster name, equal to the cluster root folder and to gitops/clusters/<name>/"
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^loc-[a-z0-9]{2,6}-[0-9]{2}$", var.name))
    error_message = "A kind cluster is named loc-<site>-<nn>, for example loc-kind-01."
  }
}

variable "kubeconfig_path" {
  description = "File the kubeconfig of the cluster is written to, kept out of ~/.kube/config"
  type        = string
  nullable    = false
}

variable "node_image" {
  description = "kindest/node image; null keeps the default of the provider's kind version. Must match kubernetesVersion of cluster.yaml"
  type        = string
  default     = null
}

variable "disable_default_cni" {
  description = "Start without kindnet and kube-proxy, for a cluster whose bootstrap installs Cilium"
  type        = bool
  default     = false
  nullable    = false
}
