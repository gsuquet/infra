output "kubeconfig_path" {
  description = "Kubeconfig file of the cluster; every cluster root has this output, the cluster:* tasks read it"
  value       = module.cluster.kubeconfig_path
}

output "argocd_ui" {
  description = "Command that opens the Argo CD UI on https://localhost:8080"
  value       = "kubectl --kubeconfig ${module.cluster.kubeconfig_path} -n argocd port-forward svc/argocd-server 8080:443"
}
