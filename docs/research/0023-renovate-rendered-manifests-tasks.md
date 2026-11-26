# Renovate rendered manifests: postUpgradeTasks

How Renovate runs a post-upgrade task and what limits it. It supports [RFC 0023](../rfc/0023-renovate-rendered-manifests.md), which holds the decision.

"verified" and "unverified" follow the [markers](0023-renovate-rendered-manifests-options.md#markers).

| Fact | Source |
| --- | --- |
| Each command must match a regex of global-only `allowedCommands` (formerly `allowedPostUpgradeCommands`); empty runs nothing; the Mend-hosted app does not allow it | docs (verified) |
| Commands are compiled from templates before the check; we use none, so anchored exact strings work | docs (verified) |
| No shell unless global `allowShellExecutorForPostUpgradeCommands`: no `&&`, one command per entry | `execute-post-upgrade-commands.js` (verified) |
| `executionMode: branch` runs once per branch; a grouped PR renders once | docs (verified) |
| Branch-mode tasks come from the branch config `{ ...config, ...config.upgrades[0] }` after sorting by `fileReplacePosition`, then `depName`: the task runs only if the first sorted upgrade carries it, else it silently never runs and the PR goes red | `generate.js` (verified) |
| `fileFilters` default to `**/*`; deleted matching files are committed, so a dropped resource removes its rendered file | docs, source (verified) |
| A failing command becomes an artifact error on the branch, not a crash; `manifests:check` stays red | source (verified) |
| `installTools` installs Containerbase tools (`mise`, `helm` listed); no effect with `binarySource=global` | docs (verified) |
| Child processes get only `basicEnvVars` (proxies, `HOME`, `PATH`, locale, CA, Corepack; no token) unless `exposeAllEnv` | docs, `util/exec/env.js` (verified) |
| Commands run with `cwd` = the clone, whose `.git/config` holds `x-access-token:` plus the token (`getRepoUrl`, `util/git/index.js`) | source (verified) |
| Refreshing `.mise/mise.lock` needs `mise` in global `allowedUnsafeExecutions`; 41.115.2 rejects the option, 44.239.1 accepts it; infra needs it today (`lockfile = true`) | docs, local run (verified) |
| `platformCommit` pushes objects to `refs/renovate/branches/<branch>`, then REST `POST /git/trees` (blob SHAs only) and `POST /git/commits`: payload bounded by file count, not size | `pushFiles` (verified); tree-entry limit (unverified) |

## Sources

- [postUpgradeTasks](https://docs.renovatebot.com/configuration-options/#postupgradetasks), [executionMode](https://docs.renovatebot.com/configuration-options/#postupgradetasksexecutionmode), [fileFilters](https://docs.renovatebot.com/configuration-options/#postupgradetasksfilefilters), [installTools](https://docs.renovatebot.com/configuration-options/#postupgradetasksinstalltools)
- [allowedCommands](https://docs.renovatebot.com/self-hosted-configuration/#allowedcommands), [exposeAllEnv](https://docs.renovatebot.com/self-hosted-configuration/#exposeallenv)
- [gitIgnoredAuthors](https://docs.renovatebot.com/configuration-options/#gitignoredauthors), [rebaseWhen](https://docs.renovatebot.com/configuration-options/#rebasewhen), [Updating and rebasing](https://docs.renovatebot.com/updating-rebasing/)
- Managers: [helmv3](https://docs.renovatebot.com/modules/manager/helmv3/), [helm-values](https://docs.renovatebot.com/modules/manager/helm-values/), [mise](https://docs.renovatebot.com/modules/manager/mise/)
- [GITHUB_TOKEN](https://docs.github.com/en/actions/concepts/security/github_token): its events start no workflow, except `workflow_dispatch`, `repository_dispatch` and `pull_request` opened/synchronize/reopened, which wait for approval (verified)
- [Triggering a workflow from a workflow](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow): an App token or PAT starts runs normally (verified)
- `gsuquet/homelab` `docs/explanation/automated-updates.md`: manual render, exact pins, `minimumReleaseAge: 3 days`, weekly batches
