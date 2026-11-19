# CLAUDE.md

IaC and GitOps for kind, Talos and GKE clusters, plus the Cloudflare account.

## Before a change

1. Read the ADRs in `docs/adr/` that the change touches: they are the decisions you follow. Done when each
   touched area (layout, bootstrap, GitOps, tenants, network, secrets, state, CI) has its ADR read.
2. Read `docs/reference/gitops-tooling.md` when you change `gitops/`, `schemas/`, `policy/` or `.mise/tasks/`.
   Done when you can name the task, schema or policy your change affects, or the change touches none of them.
3. Read `landing-zone/cloudflare/README.md` when you change `landing-zone/cloudflare/`. Done when you know which
   env file and token your change needs, or it touches no file there.

## Rules

- Never run `pass-cli`, so never `mise run tf` or `mise run tf:read` (both call it): ask the owner for the plan
  output you need instead.
- IaC is read-only: `init -backend=false` and `validate` only. No `apply`, `destroy`,
  `import`, `state`, nor anything that reads or writes remote state or calls Cloudflare. Sole exception: a
  throwaway kind cluster root with local state, no remote backend and no credentials may be applied and destroyed
  (directly or through `mise run cluster:up|down`); delete the cluster afterwards.
- OpenTofu replaces Terraform (RFC 0022, accepted). Run the IaC binary `.mise/config.toml` pins (`terraform` or
  `tofu`), never the other one.
- `gitops/clusters/<name>/rendered/` is generated: change the sources, run `mise run manifests:render`, commit
  both. CI fails on drift.
- A cluster has the same `<name>` in `clusters/` and `gitops/clusters/`.
- Public repository: write no employer or client name, nor a word that labels a context as work or personal;
  `git grep` for them before each commit.
- Pin every tool in mise (with lockfile), every GitHub Action and pre-commit hook by commit SHA with a version
  comment.
- Conventional commits; pre-commit hooks pass, never `--no-verify`.

## Docs

- Human docs (`README.md`, `docs/{concepts,how-to,reference,tutorials,runbooks}/`): write them with the
  `write-docs` skill, diagram first (Mermaid), tables over prose; link each new page from `docs/README.md`.
- Decisions: write an RFC in `docs/rfc/` with `write-docs`. An ADR is generated from an accepted RFC by the `write-docs` skill's
  `rfc-to-adr.sh`; edit the RFC, never the ADR. RFC numbers 0020-0026 are reserved by open studies: the next free
  one is 0027.
- Agent-read text (this file): follow `write-for-agents`.
- PR bodies: `describe-change`.
