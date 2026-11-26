# Renovate rendered manifests: pilot

The checks before the render task runs on the normal schedule. It supports [RFC 0023](../rfc/0023-renovate-rendered-manifests.md), which holds the decision.

"verified" and "unverified" follow the [markers](0023-renovate-rendered-manifests-options.md#markers).

## Steps

| Step | Check |
| --- | --- |
| 1 | Bump the runner, split out `renovate-infra` with its single-repo token and global options; from a throwaway task, check the `.git/config` token is rejected by another repo |
| 2 | Add the repo rules once the render task and one component exist |
| 3 | Force a chart bump (`workflow_dispatch`, `dry_run: off`): tools installed, render in Renovate's commit, deleted files removed, `manifests:check` green |
| 4 | Force a mixed run, `helm` (render tools) plus `actions/checkout` (dev tools): `render tools` re-renders, `dev tools` carries no render |
| 5 | Force a large CRD bump in every cluster (cert-manager or Argo CD major): the platform commit goes through |
| 6 | Commit still signed with the rendered files; two consecutive runs hit the cache and no GitHub rate limit |
| 7 | If `Chart.lock` is committed, force a lock file maintenance run: the `gitops/components/**` lock branch re-renders, the other lock branch carries no render |

## Local checks done

Checks done for the RFC: `renovate --platform=local --dry-run=extract` 44.239.1 on a scratch repo ([manager table](0023-renovate-rendered-manifests-managers.md)); `renovate-config-validator --strict` 44.239.1 on the repo rules and global options: pass; the same with
41.115.2 on the global options: fails on `allowedUnsafeExecutions`.
