output "kubeconfig_path" {
  description = "Kubeconfig file of the cluster"
  value       = kind_cluster.this.kubeconfig_path
}

output "cluster_id" {
  description = "Changes only when the cluster is created again: a hash of its CA certificate"
  value       = sha256(kind_cluster.this.cluster_ca_certificate)
}
