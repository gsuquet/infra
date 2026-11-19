# Terraform roots and modules reference

Every IaC root and child module of the repository, with its state and status, as of `main`.

## IaC tool

OpenTofu replaces Terraform (RFC 0022, accepted). Commands use the binary `.mise/config.toml` pins: `terraform`
until the migration lands, `tofu` after; every other page links here instead of repeating this.

## Roots

A root has a backend and provider configuration and calls child modules from `modules/`.

| Root | Purpose | State | Status |
| --- | --- | --- | --- |
| `landing-zone/cloudflare/` | R2 state bucket, domains, Zero Trust foundation, account-wide and platform Access applications | R2 `terraform-state`, key `landing-zone/cloudflare/terraform.tfstate` | exists |
| `landing-zone/gcp/` | projects, IAM and network for GKE | R2 | planned |
| `clusters/<name>/` (kind) | one kind cluster; calls only `cluster-kind` and `bootstrap-*` | local, no remote backend | planned |
| `clusters/<name>/` (Talos, GKE) | one cluster; calls only `cluster-*` and `bootstrap-*` | R2 `terraform-state`, key `clusters/<name>/terraform.tfstate`, `use_lockfile = true`, R2 flags as `landing-zone/cloudflare/backend.tf` | planned |

The Cloudflare token of a cluster root is least-privileged: it cannot edit account-wide Access. Account-wide and
platform Access applications stay in `landing-zone/cloudflare/`.

## Modules

A child module has no backend and no provider configuration. Files follow the HashiCorp standard module structure,
with the `terraform` block in `terraform.tf`. Child modules commit no lock file.

| Module | Purpose | Status |
| --- | --- | --- |
| `cloudflare-domain` | one Cloudflare zone with baseline settings, DNSSEC, CAA and mail records | exists |
| `cluster-kind` | kind cluster for developer machines; default CNI and kube-proxy disabled | planned |
| `cluster-talos` | Talos on Raspberry Pis and local servers (`siderolabs/talos` provider, no Ansible); Flannel and kube-proxy disabled in the machine config, Cilium pointed at KubePrism (`localhost:7445`); the patch differs before and from Talos 1.14 | planned |
| `cluster-gke` | GKE with Dataplane V2 and GKE Gateway API (GKE owns the CRDs); Spot pools, on-demand pools or both, chosen per cluster by input | planned |
| `bootstrap-gateway-api` | Gateway API CRDs from `gitops/clusters/<name>/rendered/gateway-api-crds/`; not called on GKE | planned |
| `bootstrap-cilium` | Cilium from `rendered/cilium/`; not called on GKE | planned |
| `bootstrap-argocd` | Argo CD and its root `Application` from `rendered/argocd/` | planned |

Bootstrap modules apply the rendered manifests once, then Argo CD adopts them; they must not revert Argo CD's later
changes.

## Lock files

Each root's `.terraform.lock.hcl` hashes `darwin_arm64`, `linux_amd64` and `linux_arm64`. The
`terraform_providers_lock` pre-commit hook checks them and regenerates a lock file only when a platform is missing.
Child modules commit no lock file (`.gitignore`).
