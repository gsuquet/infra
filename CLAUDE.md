# CLAUDE.md

Terraform and GitOps for the platform: kind, Talos and GKE clusters, plus the Cloudflare account.
Read [`README.md`](README.md) and the decisions in [`docs/adr/`](docs/adr/README.md) before structural changes.

## Layout

* `landing-zone/{cloudflare,gcp}/`: Terraform roots for account foundations.
* `modules/`: every Terraform child module (`cluster-*`, `bootstrap-*`, `cloudflare-domain`, ...).
* `clusters/<name>/`: one Terraform root per cluster; kind uses local state, others R2
  (`clusters/<name>/terraform.tfstate`).
* `gitops/components/<name>/`: catalog. `gitops/clusters/<name>/cluster.yaml`: enabled components, overrides,
  tenants. `gitops/clusters/<name>/rendered/`: generated, never edit by hand.
* `gitops/tenants/<tenant>.yaml`: tenant onboarding. Tenant manifests live in `gsuquet/gitops`.

## Tasks

* `mise install`: pinned tools (`.mise/config.toml` + `.mise/mise.lock`).
* `pre-commit run --all-files`: static checks, the same as CI.
* `mise run manifests:render|check` and `mise run cluster:up|plan|down <name>` (planned, ADR-0019).

## Rules for agents

* Never run `pass-cli`, so never `mise run tf` or `mise run tf:read` (both call it).
* Terraform is read-only for agents: `terraform init -backend=false` and `terraform validate` only. Never
  `apply`, `destroy`, `import`, `state` or anything that reads or writes remote state or calls Cloudflare.
* A throwaway local kind cluster is allowed for tests; delete it afterwards.
* Public repository: never write employer or client names, nor words that label a context as work or
  personal. Before each commit, check `git grep` for them.
* Pin every tool in mise (with lockfile) and every GitHub Action and pre-commit hook by commit SHA with a version
  comment.
* Conventional commits; pre-commit hooks must pass, never `--no-verify`.
* New structural decision: add an ADR (next free number; 0020 is reserved for the secrets backend).
