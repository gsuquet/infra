# shellcheck shell=bash
# Shared helpers of the cluster:* tasks. Not a task: no shebang.

# The Application that manages argo-cd-apps itself: the root the bootstrap
# applies, and the sign that a cluster is already bootstrapped.
ROOT_APPLICATION="argo-cd-apps"
ARGOCD_NAMESPACE="argocd"

# cluster_root <cluster>: the Terraform root, checked.
cluster_root() {
  local dir="clusters/$1"
  [ -f "$dir/main.tf" ] || {
    log_error "$dir is not a cluster root"
    exit 1
  }
  printf '%s\n' "$dir"
}

# cluster_file <cluster>: the GitOps cluster file, checked.
cluster_file() {
  local file="gitops/clusters/$1/cluster.yaml"
  [ -f "$file" ] || {
    log_error "$file is missing"
    exit 1
  }
  printf '%s\n' "$file"
}

# cluster_kubeconfig <cluster>: the kubeconfig file the root outputs, never the
# user's current context, so a task cannot act on the wrong cluster.
cluster_kubeconfig() {
  local root path
  root="$(cluster_root "$1")"
  path="$(terraform -chdir="$root" output -raw kubeconfig_path 2> /dev/null)" || {
    log_error "$root has no kubeconfig_path output: create the cluster first (mise run cluster:up $1)"
    exit 1
  }
  case "$path" in
    /*) ;;
    *) path="$root/$path" ;;
  esac
  [ -f "$path" ] || {
    log_error "kubeconfig $path does not exist"
    exit 1
  }
  printf '%s\n' "$path"
}

# bootstrapped: true when the root Application exists (KUBECONFIG set).
bootstrapped() {
  kubectl get application --namespace "$ARGOCD_NAMESPACE" "$ROOT_APPLICATION" > /dev/null 2>&1
}
