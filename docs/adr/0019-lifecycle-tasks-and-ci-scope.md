---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Drive lifecycles with mise tasks and keep CI to static checks

## Context and Problem Statement

Operators and agents need the same commands to create, plan, destroy clusters and render manifests. CI must
catch errors on pull requests without cloud credentials. Which entry points exist, and what does CI run?

## Decision Drivers

* One entry point per action, the same on a laptop and in CI.
* No credential in CI for this public repository.
* Fast pull request feedback.

## Considered Options

* mise tasks + static CI (pre-commit, `manifests:check`, kubeconform, Conftest)
* Makefile + CI with `terraform plan`
* Full end-to-end CI with a kind cluster per pull request

## Decision Outcome

Chosen option: "mise tasks + static CI".

| Task | Action |
| --- | --- |
| `mise run cluster:up <name>` | init and apply `clusters/<name>/` |
| `mise run cluster:plan <name>` | plan `clusters/<name>/` |
| `mise run cluster:down <name>` | destroy `clusters/<name>/` |
| `mise run manifests:render` | render every enabled component of every cluster |
| `mise run manifests:check` | render and fail on any difference with Git |

CI on pull requests: pre-commit static checks, `manifests:check`, kubeconform and Conftest on `rendered/`.
`terraform plan` stays local.

### Consequences

* Good, because CI needs no secret and cannot touch remote state.
* Good, because every tool version is pinned in `.mise/config.toml` with a lockfile.
* Bad, because Terraform changes are not planned in CI: the author runs `cluster:plan` locally and pastes the
  relevant output in the pull request.
* Deferred: a kind end-to-end CI job (create cluster, bootstrap, wait for Argo CD healthy).

### Confirmation

The CI workflow (not yet written) calls only mise tasks and pre-commit; no workflow references Terraform
credentials.

## Pros and Cons of the Options

### mise tasks + static CI

* Good, because simple, safe, fast.
* Bad, because runtime regressions are found only locally.

### Makefile + CI plan

* Good, because plan visible in review.
* Bad, because credentials in a public repository's CI.

### Full kind e2e per pull request

* Good, because catches runtime errors.
* Bad, because slow, and the bootstrap does not exist yet.
