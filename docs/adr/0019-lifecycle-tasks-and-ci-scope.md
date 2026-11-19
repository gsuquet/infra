---
adr: 0019
title: Drive lifecycles with mise tasks and keep CI static
status: accepted
date: 2026-11-18
rfc: docs/rfc/0019-lifecycle-tasks-and-ci-scope.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0019. Drive lifecycles with mise tasks and keep CI static

- Status: accepted on 2026-11-18 by gsuquet
- Decision: In the context of lifecycle commands shared by operators, agents and CI in a public repository, facing CI that must stay free of credentials, we decided for mise tasks as the only entry points (`cluster:up|plan|down <name>` to init and apply, plan or destroy `clusters/<name>/`; `manifests:render` and `manifests:check`) and a pull request CI limited to static checks (pre-commit, `manifests:check`, kubeconform and Conftest on `rendered/`), with plans run locally, and against a Makefile with a CI plan and a kind end-to-end job per pull request, to achieve the same commands everywhere and a CI with no secret, accepting that IaC changes and runtime regressions are checked only locally.
- Consequences:
  - Good: CI needs no secret and cannot touch remote state.
  - Good: every tool version is pinned in `.mise/config.toml` with a lockfile.
  - Bad: IaC changes are not planned in CI: the author runs `cluster:plan` locally and pastes the relevant output in the pull request.
  - Bad: runtime regressions are found only locally until a kind end-to-end job exists.
- Confidence: high, static checks cover the rendered output that reaches clusters.
- Confirmation: the CI workflow calls only mise tasks and pre-commit; no workflow references IaC or cloud credentials.
- Revisit when: the bootstrap exists and a kind end-to-end job fits in pull request time.

Source: [RFC 0019](../../docs/rfc/0019-lifecycle-tasks-and-ci-scope.md), reviewed in https://github.com/gsuquet/infra/pull/5.
