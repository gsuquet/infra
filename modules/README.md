# Modules

Every Terraform child module of the repository. A child module has no backend and no provider configuration:
the root modules in [`landing-zone/`](../landing-zone/) and [`clusters/`](../clusters/) call it.

| Module | Purpose | Status |
| --- | --- | --- |
| `cloudflare-domain` | One Cloudflare zone with baseline settings, DNSSEC, CAA and mail records | moving from `landing-zone/cloudflare/modules/domain` (PR #3) |
| `cluster-kind` | kind cluster for developer machines, default CNI and kube-proxy disabled | planned |
| `cluster-talos` | Talos cluster on Raspberry Pis and local servers (`siderolabs/talos` provider) | planned |
| `cluster-gke` | GKE cluster with Dataplane V2 and GKE Gateway API (GKE owns the Gateway API CRDs) | planned |
| `bootstrap-gateway-api` | Gateway API CRDs from `gitops/clusters/<name>/rendered/gateway-api-crds/` (not on GKE) | planned |
| `bootstrap-cilium` | Cilium from `rendered/cilium/` (not on GKE) | planned |
| `bootstrap-argocd` | Argo CD and its root Application from `rendered/argocd/` | planned |

Bootstrap modules apply the rendered manifests once; Argo CD then adopts them. Files follow the HashiCorp standard
module structure, with the `terraform` block in `terraform.tf`.
