# infra

Terraform and GitOps for the platform: Kubernetes clusters on developer machines (kind), Raspberry Pis and local
servers (Talos) and Google Cloud (GKE), plus the Cloudflare account that fronts them.

`infra` is the greenfield successor of `gsuquet/homelab`, which stays frozen and keeps running the production
k3s cluster until a Talos cluster from this repository replaces it.

## Platform

* **Clusters**: kind, Talos (`siderolabs/talos` provider, no Ansible) and GKE, each created by Terraform.
* **Bootstrap**: Terraform installs only the cluster, the Gateway API CRDs, Cilium and Argo CD; Argo CD adopts
  them and installs everything else.
* **GitOps**: one vanilla, self-managed Argo CD per cluster, applying committed, rendered manifests with sync
  waves.
* **Catalog**: components in `gitops/components/`, enabled per cluster in `cluster.yaml`. Baseline:
  `gateway-api-crds` (not GKE, which owns its CRDs), `cilium` (not GKE), `argocd`, `cert-manager`, `external-secrets`.
* **Networking**: Cilium with kube-proxy replacement (GKE: Dataplane V2), Gateway API with one CRD owner,
  public exposure through Cloudflare Tunnel, cluster-wide default-deny network policy.
* **Tenants**: application code in its own repositories, rendered tenant manifests in `gsuquet/gitops`,
  promoted by Kargo with git-only steps, onboarded from `gitops/tenants/`.
* **Secrets**: External Secrets Operator with a store named `secrets` in every namespace; the backend is still open.

## Layout

```text
landing-zone/cloudflare/   Cloudflare account: R2 state bucket, domains, Zero Trust
landing-zone/gcp/          GCP foundations for GKE (planned)
modules/                   every Terraform child module
clusters/<name>/           one Terraform root per cluster
gitops/components/<name>/  component catalog: Helm source and default values
gitops/clusters/<name>/    cluster.yaml and rendered/<component>/
gitops/tenants/            one file per tenant
docs/reference/            tooling reference (gitops-tooling.md)
```

Each folder has a README.

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

`pre-commit run --all-files` runs the static checks. CI ([`checks.yml`](.github/workflows/checks.yml)) runs them
on pull requests only, and the GitOps tasks (`manifests:check`, kubeconform, Conftest) on every pull request and
push to main. `mise run
cluster:up|plan|down <name>` is planned. `terraform plan` stays local.

Work is tracked as GitHub issues.

## License

[LICENSE](LICENSE)
