# Architecture decision records

Decisions use [MADR](https://adr.github.io/madr/) (see [ADR-0001](0001-record-decisions-with-madr.md)).
Add a decision as `NNNN-title-with-dashes.md` with the next free number and list it here. Supersede an
accepted ADR with a new one instead of rewriting it.

| ADR | Title | Status |
| --- | --- | --- |
| [0001](0001-record-decisions-with-madr.md) | Record architecture decisions with MADR | accepted |
| [0002](0002-greenfield-successor-of-homelab.md) | Build infra as a greenfield successor of homelab | accepted |
| [0003](0003-cluster-distribution-per-target.md) | Use kind, Talos and GKE as cluster distributions per target | accepted |
| [0004](0004-self-managed-argo-cd-per-cluster.md) | Run one self-managed Argo CD per cluster | accepted |
| [0005](0005-rendered-manifests-pattern.md) | Commit rendered manifests and apply them with sync waves | accepted |
| [0006](0006-component-catalog-and-cluster-file.md) | Define components in a catalog and enable them per cluster in cluster.yaml | accepted |
| [0007](0007-tenant-manifests-in-gitops-repo.md) | Keep tenant application code in its own repositories and rendered tenant manifests in gsuquet/gitops | accepted |
| [0008](0008-kargo-git-only-promotion.md) | Promote tenant releases with Kargo using git-only steps | accepted |
| [0009](0009-tenant-onboarding-by-infra.md) | Onboard tenants from infra with a tenant file and a per-cluster tenant list | accepted |
| [0010](0010-cluster-owned-default-deny-network-policy.md) | Own network policy at the cluster layer with a label-selected default deny | accepted |
| [0011](0011-cilium-cni-and-gke-dataplane-v2.md) | Use Cilium with kube-proxy replacement on kind and Talos, and Dataplane V2 on GKE | accepted |
| [0012](0012-gateway-api-crd-ownership.md) | Use Gateway API with one component owning its CRDs and swappable implementations | accepted |
| [0013](0013-public-exposure-via-cloudflare-tunnel.md) | Expose public services through Cloudflare Tunnel | accepted |
| [0014](0014-baseline-components.md) | Install a fixed set of baseline components on every cluster | accepted |
| [0015](0015-bootstrap-boundary.md) | Limit Terraform bootstrap to the cluster, Gateway API CRDs, Cilium and Argo CD | accepted |
| [0016](0016-secret-store-named-secrets.md) | Read secrets through an External Secrets store named secrets in every namespace | accepted |
| [0017](0017-repository-layout.md) | Organise the repository by landing zones, modules, cluster roots and gitops | accepted |
| [0018](0018-terraform-state-backends.md) | Store kind state locally and other cluster states in the R2 backend | accepted |
| [0019](0019-lifecycle-tasks-and-ci-scope.md) | Drive lifecycles with mise tasks and keep CI to static checks | accepted |
| 0020 | Secrets backend | reserved (proposed in a separate pull request; link it here when merged) |
