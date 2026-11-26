# CLAUDE.md

Terraform and GitOps for the platform: kind, Talos and GKE clusters, plus the Cloudflare account.
Read [`README.md`](README.md) before structural changes.

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
* `pre-commit run --all-files`: static checks. CI (`.github/workflows/checks.yml`) runs them and the GitOps
  tasks on every pull request.
* `mise run manifests:render|check`; `mise run cluster:up|plan|down <name>` is planned.

## Rules for agents

* Never run `pass-cli`, so never `mise run tf` or `mise run tf:read` (both call it).
* OpenTofu is read-only for agents: `tofu init -backend=false` and `tofu validate` only (or
  `pre-commit run terraform_validate --all-files`, which runs them with `--tf-path=tofu`). Never
  `apply`, `destroy`, `import`, `state` or anything that reads or writes remote state or calls Cloudflare.
* Only exception: a throwaway local kind cluster for tests. `apply` and `destroy` (directly or through
  `mise run cluster:up|down`) are allowed on a kind cluster root with local state, no remote backend and no
  credentials. Delete the cluster afterwards.
* Public repository: never write employer or client names, nor words that label a context as work or
  personal. Before each commit, check `git grep` for them.
* Pin every tool in mise (with lockfile) and every GitHub Action and pre-commit hook by commit SHA with a version
  comment.
* Conventional commits; pre-commit hooks must pass, never `--no-verify`.
* Work is tracked as GitHub issues.
