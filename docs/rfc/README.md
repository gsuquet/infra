# Requests for comments

Every structural decision starts here as an RFC, reviewed in a pull request
([RFC 0001](0001-record-decisions-with-madr.md)). An accepted RFC generates the ADR with the same number in
[`docs/adr/`](../adr/README.md). Numbers 0020 to 0026 are pre-assigned to open studies.

| RFC | Title | Status |
| --- | --- | --- |
| [0001](0001-record-decisions-with-madr.md) | Record decisions as RFCs with generated ADRs | accepted |
| [0002](0002-greenfield-successor-of-homelab.md) | Build infra as a greenfield successor of homelab | accepted |
| [0003](0003-cluster-distribution-per-target.md) | Use kind, Talos and GKE as distributions per target | accepted |
| [0004](0004-self-managed-argo-cd-per-cluster.md) | Run one self-managed Argo CD per cluster | accepted |
| [0005](0005-rendered-manifests-pattern.md) | Commit rendered manifests and apply them with sync waves | accepted |
| [0006](0006-component-catalog-and-cluster-file.md) | Define a component catalog and a cluster.yaml per cluster | accepted |
| [0007](0007-tenant-manifests-in-gitops-repo.md) | Keep tenant manifests in gsuquet/gitops, code in app repos | accepted |
| [0008](0008-kargo-git-only-promotion.md) | Promote tenant releases with Kargo git-only steps | accepted |
| [0009](0009-tenant-onboarding-by-infra.md) | Onboard tenants from infra with tenant files | accepted |
| [0010](0010-cluster-owned-default-deny-network-policy.md) | Enforce a label-selected default deny network policy | accepted |
| [0011](0011-cilium-cni-and-gke-dataplane-v2.md) | Use Cilium on kind and Talos, Dataplane V2 on GKE | accepted |
| [0012](0012-gateway-api-crd-ownership.md) | Give Gateway API CRDs one owner per cluster | accepted |
| [0013](0013-public-exposure-via-cloudflare-tunnel.md) | Expose public services through Cloudflare Tunnel | accepted |
| [0014](0014-baseline-components.md) | Install a fixed baseline of components on every cluster | accepted |
| [0015](0015-bootstrap-boundary.md) | Limit bootstrap to cluster, Gateway CRDs, Cilium, Argo CD | accepted |
| [0016](0016-secret-store-named-secrets.md) | Read secrets through an ESO store named secrets | accepted |
| [0017](0017-repository-layout.md) | Organise infra by landing zones, modules, clusters, gitops | accepted |
| [0018](0018-terraform-state-backends.md) | Keep kind state local and other cluster states in R2 | accepted |
| [0019](0019-lifecycle-tasks-and-ci-scope.md) | Drive lifecycles with mise tasks and keep CI static | accepted |
| 0020 | Back the ESO store secrets with GCP Secret Manager | draft, [#4](https://github.com/gsuquet/infra/pull/4) |
| 0021 | Promote tenant releases with one standalone Kargo | draft, [#8](https://github.com/gsuquet/infra/pull/8) |
| 0022 | Use OpenTofu as the IaC tool | accepted, lands with [#11](https://github.com/gsuquet/infra/pull/11) |
| 0023 | Re-render manifests in Renovate's own commit | draft, [#6](https://github.com/gsuquet/infra/pull/6) |
| 0024 | Run GKE Standard zonal with Dataplane V2 as the cloud target | draft, [#7](https://github.com/gsuquet/infra/pull/7) |
| 0025 | Build Talos clusters on Raspberry Pis with cluster-talos | draft, [#9](https://github.com/gsuquet/infra/pull/9) |
| 0026 | Expose each cluster through its own Cloudflare Tunnel | draft, [#10](https://github.com/gsuquet/infra/pull/10) |
