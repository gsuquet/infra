# infra

IaC and GitOps for kind, Talos and GKE clusters, plus the Cloudflare account.

## Before a change

1. Read the ADRs in `docs/adr/` that the change touches: they are the decisions you follow. Done when each
   touched area (layout, bootstrap, GitOps, tenants, network, secrets, state, CI) has its ADR read.
2. Read `docs/reference/gitops-tooling.md` when you change `gitops/`, `schemas/`, `policy/` or `.mise/tasks/`.
   Done when you can name each task, schema and policy your change affects, or it touches none of these folders.
3. Read `landing-zone/cloudflare/README.md` when you change `landing-zone/cloudflare/`. Done when you know each
   env file and token your change needs, or it touches no file there.

## Rules

- Ask the owner for any plan output you need. Never run `pass-cli`, `mise run tf` or `mise run tf:read` (both
  tasks call it).
- IaC is read-only: run `init -backend=false` and `validate` only. Never run `apply`, `destroy`, `import`, `state`,
  nor anything that reads or writes remote state or calls Cloudflare. Sole exception: a throwaway kind cluster
  root with local state, no remote backend and no credentials may be applied and destroyed (directly or through
  `mise run cluster:up|down`); delete the cluster afterwards.
- Run the IaC binary `.mise/config.toml` pins (`terraform` or `tofu`), never the other one: OpenTofu replaces
  Terraform (RFC 0022, accepted).
- Change the sources of `gitops/clusters/<name>/rendered/`, run `mise run manifests:render` and commit both: the
  folder is generated. CI fails on drift.
- Give a cluster the same `<name>` in `clusters/` and `gitops/clusters/`.
- Public repository: write no employer or client name, nor a word that labels a context as work or personal;
  `git grep` for them before each commit.
- Pin every tool in mise (with lockfile), and every GitHub Action and pre-commit hook by commit SHA with a version
  comment.
- Use Conventional Commits. Fix a failing hook; never use `--no-verify`.

## Writing

- When you write a human doc (`README.md`, `docs/{concepts,how-to,reference,tutorials,runbooks}/`), follow the
  `write-docs` skill, diagram first (Mermaid), tables over prose, and link each new page from `docs/README.md`.
- When you record a decision, write an RFC in `docs/rfc/` with `write-docs`. Edit the RFC, never the ADR: the skill
  generates the ADR from the accepted RFC. Open studies reserve RFC numbers 0020-0026: the next free one is 0027.
- When you edit this file, follow `write-for-agents`.
- When you write a PR title or body, follow `describe-change`.
