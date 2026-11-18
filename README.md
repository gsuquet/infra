# infra

Terraform and GitOps for the platform: Kubernetes clusters on developer machines (kind), Raspberry Pis and local
servers (Talos) and Google Cloud (GKE), plus the Cloudflare account that fronts them.

`infra` is the greenfield successor of `gsuquet/homelab`, which stays frozen and keeps running the production
k3s cluster until a Talos cluster from this repository replaces it
([ADR-0002](docs/adr/0002-greenfield-successor-of-homelab.md)).

## Platform

* **Clusters**: kind, Talos (`siderolabs/talos` provider, no Ansible) and GKE, each created by Terraform
  ([ADR-0003](docs/adr/0003-cluster-distribution-per-target.md)).
* **Bootstrap**: Terraform installs only the cluster, the Gateway API CRDs, Cilium and Argo CD; Argo CD adopts
  them and installs everything else ([ADR-0015](docs/adr/0015-bootstrap-boundary.md)).
* **GitOps**: one vanilla, self-managed Argo CD per cluster
  ([ADR-0004](docs/adr/0004-self-managed-argo-cd-per-cluster.md)), applying committed, rendered manifests
  with sync waves ([ADR-0005](docs/adr/0005-rendered-manifests-pattern.md)).
* **Catalog**: components in `gitops/components/`, enabled per cluster in `cluster.yaml`
  ([ADR-0006](docs/adr/0006-component-catalog-and-cluster-file.md)). Baseline: `gateway-api-crds` (not
  GKE, which owns its CRDs), `cilium` (not GKE), `argocd`, `cert-manager`, `external-secrets`
  ([ADR-0014](docs/adr/0014-baseline-components.md)).
* **Networking**: Cilium with kube-proxy replacement (GKE: Dataplane V2), Gateway API with one CRD owner,
  public exposure through Cloudflare Tunnel, cluster-wide default-deny network policy
  ([ADR-0010](docs/adr/0010-cluster-owned-default-deny-network-policy.md) to
  [ADR-0013](docs/adr/0013-public-exposure-via-cloudflare-tunnel.md)).
* **Tenants**: application code in its own repositories, rendered tenant manifests in `gsuquet/gitops`,
  promoted by Kargo with git-only steps, onboarded from `gitops/tenants/`
  ([ADR-0007](docs/adr/0007-tenant-manifests-in-gitops-repo.md) to
  [ADR-0009](docs/adr/0009-tenant-onboarding-by-infra.md)).
* **Secrets**: External Secrets Operator with a store named `secrets` in every namespace; the backend is still
  open ([ADR-0016](docs/adr/0016-secret-store-named-secrets.md)).

## Layout

```text
landing-zone/cloudflare/   Cloudflare account: R2 state bucket, domains, Zero Trust
landing-zone/gcp/          GCP foundations for GKE (planned)
modules/                   every Terraform child module
clusters/<name>/           one Terraform root per cluster
gitops/components/<name>/  component catalog: Helm source and default values
gitops/clusters/<name>/    cluster.yaml and rendered/<component>/
gitops/tenants/            one file per tenant
docs/adr/                  architecture decision records
```

Each folder has a README. Decisions are indexed in [`docs/adr/`](docs/adr/README.md).

## Usage

Tools are pinned in `.mise/config.toml` with a lockfile:

```sh
mise install
pre-commit install --install-hooks
pre-commit install --hook-type commit-msg
```

The Cloudflare landing zone runs through `mise run tf` (write token) and `mise run tf:read` (read-only token);
credentials and the first-apply bootstrap are described in
[`landing-zone/cloudflare/README.md`](landing-zone/cloudflare/README.md).

`pre-commit run --all-files` runs the static checks. There is no CI workflow yet: CI on pull requests (pre-commit,
`manifests:check`, kubeconform, Conftest) is planned in
[ADR-0019](docs/adr/0019-lifecycle-tasks-and-ci-scope.md), together with `mise run cluster:up|plan|down <name>`
and `mise run manifests:render|check`. `terraform plan` stays local.

## License

[LICENSE](LICENSE)
