# Renovate and rendered manifests study

Status: input for a future ADR. Research date: 2026-11-18.

`gitops/components/<name>/` holds the Helm source and default values of each component. `mise run manifests:render`
writes the output to `gitops/clusters/<cluster>/rendered/<component>/`, and CI fails when the committed output is
stale (`mise run manifests:check`). A Renovate PR that bumps a chart, an image tag in default values, or a render
tool (helm, yq, kustomize via mise) changes the render output, so the same PR must carry the new render. This study
compares the ways to do that and recommends one.

Facts marked **(verified)** were checked on the date above against the linked page of docs.renovatebot.com or
docs.github.com, or by running Renovate locally (see [Local checks](#local-checks)). Facts marked **(unverified)**
come from prior knowledge or from a source outside the allowed documentation domains. Check them before you build
on them.

## Prior art (homelab)

`gsuquet/homelab` `docs/explanation/automated-updates.md` has no post-upgrade task: a Renovate PR that changes a
`Chart.yaml` fails `Validate Kubernetes Manifests`, and "a person or an agent runs the render on the PR branch". It
also pins everything exactly, waits 3 days (`minimumReleaseAge`), batches PRs weekly, and automerges only the
`dev tools` group. In infra, automerge stays off for everything (owner rule: humans merge).

That manual step does not scale to N clusters times M components, and it breaks Renovate's own maintenance: once a
person pushes the render commit, Renovate stops updating the branch (see [option B](#b-github-actions-workflow-pushes-the-render-to-the-renovate-branch)).

## Constraints

| Constraint | Consequence |
| --- | --- |
| Public repo, CI must hold no secret ([ADR-0019](../adr/0019-lifecycle-tasks-and-ci-scope.md) driver: "No credential in CI for this public repository"; the ADR lands with PR #5, so this link resolves once that PR is merged). | Any option that needs a write token in infra's CI goes against an accepted ADR. |
| The owner self-hosts Renovate: `gsuquet/renovate-bot` runs `renovatebot/github-action` on a schedule with a GitHub App token, `autodiscover` over `gsuquet/*`, `platformCommit: enabled`, image `ghcr.io/renovatebot/renovate:41.115.2`. | Global (admin-only) options such as `allowedCommands` are in the owner's hands. |
| Humans merge every PR. | No automerge, no `ignoreTests`. A red PR is acceptable only if the fix is obvious. |
| The render is a mise task with tool versions pinned in `.mise/config.toml` + `.mise/mise.lock`. | Whatever renders must run the same task with the same tools, or the output differs and `manifests:check` fails. |
| Tool, action and Terraform provider bumps do not touch `gitops/`, except render tools in `.mise/config.toml`. | Only some update kinds need a render. |

## Which Renovate managers see our component format

Checked with Renovate 44.239.1 in `--platform=local --dry-run=extract` mode on a scratch repo **(verified)**:

| Source of the version | Manager | Default match | Result |
| --- | --- | --- | --- |
| Umbrella `gitops/components/<name>/Chart.yaml` with `dependencies[].version` | `helmv3` | `/(^|/)Chart\.ya?ml$/` ([helmv3](https://docs.renovatebot.com/modules/manager/helmv3/), **verified**) | Extracted, datasource `helm`, registry from `repository`. OCI charts use datasource `docker` (supported datasources `docker`, `helm`, **verified**). |
| A custom file, e.g. `gitops/components/<name>/component.yaml` with `chart.repository/name/version` | `custom.regex` with `datasourceTemplate: helm` | none, must be configured | Extracted with the regex below. |
| Image tags in `gitops/components/<name>/values.yaml` (`image.repository` + `image.tag`, nested keys too) | `helm-values` | `/(^|/)values\.ya?ml$/` ([helm-values](https://docs.renovatebot.com/modules/manager/helm-values/), **verified**) | Extracted, including `argo-cd.global.image` under an umbrella key. |
| Image or chart overrides in `gitops/clusters/<name>/cluster.yaml` | none by default | - | Needs a `custom.regex` on a `# renovate:` comment, as homelab does. Better: forbid version overrides in `cluster.yaml` (schema rule) so one version lives in the catalog. |
| `gitops/clusters/*/rendered/**` | none by default | - | Not extracted, even without `ignorePaths` **(verified)**. Add `ignorePaths` anyway: a broad custom regex (homelab matches every `*.yaml`) would start bumping generated files. |
| Render tools in `.mise/config.toml` | `mise` | includes `**/.mise/config{,.*}.toml` ([mise](https://docs.renovatebot.com/modules/manager/mise/), **verified**) | Extracted. |

Custom manager for the `component.yaml` shape (extracted as `cert-manager` `v1.19.1` from `https://charts.jetstack.io`,
**verified**):

```json
{
  "customType": "regex",
  "managerFilePatterns": ["/^gitops/components/[^/]+/component\\.yaml$/"],
  "datasourceTemplate": "helm",
  "matchStrings": [
    "chart:\\s*\\n\\s+repository:\\s*(?<registryUrl>\\S+)\\s*\\n\\s+name:\\s*(?<depName>\\S+)\\s*\\n\\s+version:\\s*(?<currentValue>\\S+)"
  ]
}
```

Recommendation: an umbrella `Chart.yaml` per component. It needs no custom manager, handles OCI and repository
aliases (`registryAliases`, **verified**) natively, and is what homelab already renders. The regex is order- and
indentation-sensitive and must be kept in step with the file format.

Notes:

- With a committed `Chart.lock`, `helmv3` updates it as an artifact, which needs `helm` in the Renovate environment
  **(unverified for artifact updates; the helmv3 page only states that lock file maintenance runs the package
  manager, verified)**. With `binarySource=install` (default) Renovate installs helm through Containerbase
  **(unverified that it does so automatically for helmv3)**.
- An image tag in default values usually tracks the chart's `appVersion`. A separate image PR can then disagree
  with the chart PR. Either leave image tags out of default values (let the chart decide) or group them with the
  chart (see [Grouping](#grouping)).
- The `mise` manager reports `skipReason: github-token-required` without a token: in the self-hosted run the App
  token covers it **(verified locally that the skip happens without a token; unverified in the runner)**.

## Options

### A. Renovate `postUpgradeTasks` (self-hosted)

Renovate runs commands after it updates the files and before it commits, then adds the changed files that match
`fileFilters` to its own commit ([postUpgradeTasks](https://docs.renovatebot.com/configuration-options/#postupgradetasks),
**verified**).

Facts:

- Each command must match a regex in the global-only `allowedCommands`; an empty list runs nothing. The option was
  formerly `allowedPostUpgradeCommands` ([self-hosted configuration](https://docs.renovatebot.com/self-hosted-configuration/#allowedcommands),
  **verified**). The Mend-hosted app does not let users set it, so this needs the self-hosted runner, which the
  owner has.
- Commands are compiled from templates before the `allowedCommands` check ([postUpgradeTasks.commands](https://docs.renovatebot.com/configuration-options/#postupgradetaskscommands),
  **verified**). We use no template, so the allow list can be anchored exact strings.
- Commands run without a shell unless the global `allowShellExecutorForPostUpgradeCommands` is set (Renovate
  44.239.1 source, `execute-post-upgrade-commands.js`, **verified**). So no `&&`: one command per list entry.
- `executionMode: branch` runs the set once per branch instead of once per update
  ([executionMode](https://docs.renovatebot.com/configuration-options/#postupgradetasksexecutionmode), **verified**).
  A grouped PR renders once. Caveat (44.239.1 source, **verified**): branch-mode tasks come from the *branch* config,
  which `workers/repository/updates/generate.js` builds as `{ ...config, ...config.upgrades[0] }` after sorting the
  upgrades by `fileReplacePosition`, then `depName`. `execute-post-upgrade-commands.js` then reads
  `config.postUpgradeTasks` from that branch config. So a branch-mode task runs only if the *first* upgrade after
  sorting carries it. In a group that mixes matching and non-matching upgrades (for example `dev tools` with
  `actions/checkout` and a `helm` mise bump), the task silently never runs and the PR goes red. Rule: attach
  branch-mode tasks only to rules that match every upgrade of the branch.
- `fileFilters` default to `**/*` ([fileFilters](https://docs.renovatebot.com/configuration-options/#postupgradetasksfilefilters),
  **verified**). Deleted files are committed when they match `fileFilters` (44.239.1 source, **verified**), so a
  chart that drops a resource removes its rendered file.
- A failing command becomes an "artifact error" on the branch, not a crash (44.239.1 source, **verified**). The PR
  shows it, and `manifests:check` stays red.
- `installTools` installs Containerbase tools before the commands; `mise` and `helm` are in the list. It has no
  effect with `binarySource=global` ([installTools](https://docs.renovatebot.com/configuration-options/#postupgradetasksinstalltools),
  **verified**).
- Renovate passes only a limited set of environment variables to child processes unless `exposeAllEnv` is set
  ([exposeAllEnv](https://docs.renovatebot.com/self-hosted-configuration/#exposeallenv), **verified**; the list is
  `basicEnvVars` in `util/exec/env.js`: proxies, `HOME`, `PATH`, locale, CA and Corepack variables, no token).
  The environment is not where the token is, though: see the first cost below.
- Commands run with `cwd` set to the repository clone (`execute-post-upgrade-commands.js`, `cwd: workingDir`,
  44.239.1 source, **verified**).
- Refreshing `.mise/mise.lock` after a mise tool bump needs `mise` in the global `allowedUnsafeExecutions`
  ([mise manager](https://docs.renovatebot.com/modules/manager/mise/), **verified**). The validator of Renovate
  41.115.2 (the runner's version) rejects `allowedUnsafeExecutions`; 44.239.1 accepts it (local run, **verified**).
  This affects infra today, render or not: `.mise/config.toml` sets `lockfile = true`.

Because the render is part of Renovate's single commit, every Renovate rebase recomputes it. There is no extra
commit, no "modified branch", no loop, and no token in infra's CI.

Costs:

- **The Renovate token is readable by every post-upgrade command** (44.239.1 source, **verified**).
  `modules/platform/github/utils.js` `getRepoUrl` builds the clone URL with `username = "x-access-token"` and
  `password = <token>`; `util/git/index.js` clones with that URL (or `git remote set-url origin` on a reused
  clone). The token therefore sits in `.git/config` of the working directory, which is the commands' `cwd`. One
  `cat .git/config` from `mise run manifests:render`, from any mise-installed binary, or from a mise hook or env
  template (trusted by `mise trust --yes`) reads it. Today `gsuquet/renovate-bot` mints that token with
  `owner: gsuquet` and no `repositories` input (`.github/workflows/renovate.yaml`, **verified**), so it is valid
  for every repository of the installation, likely including `gsuquet/renovate-bot` itself, which holds
  `RENOVATE_PRIVATE_KEY` **(installation scope and App permissions unverified: they need the App settings page)**.
  If the App has `workflows: write` (Renovate needs it to bump actions in workflow files **(unverified)**), a
  malicious render could push a workflow to `renovate-bot` that exfiltrates the App key.
- Consequence: the anchored `allowedCommands` list is **not a security boundary**. It limits which argv Renovate
  spawns, but `mise run manifests:render` runs whatever the branch's task files say, and `mise install` runs
  whatever the branch's `.mise/config.toml` pins. The only effective controls are the token's scope and what code
  lands on the branch (`minimumReleaseAge: 3 days`, `.mise/mise.lock` checksums, review of task changes on `main`).
  The recommended design below therefore isolates infra in its own runner job with a single-repo token.
- The runner is an ephemeral `ubuntu-latest` job running the Renovate container: there is no cross-run cache.
  Every run downloads mise, every render tool and every chart again unless the workflow adds `actions/cache` for
  the mise and Containerbase directories mounted into the container **(cache paths unverified)**.
- `mise install` inside the container has no GitHub token (filtered env, above). mise's GitHub-hosted backends
  (`github:`, `aqua:`, `ubi:`) then use the unauthenticated GitHub API limit of 60 requests per hour per IP, shared
  with every job on the same runner IP **(mise behaviour unverified)**. Expect intermittent artifact errors. The
  fix is a read-only, single-repo token passed through the global `customEnvVariables` (for example as
  `MISE_GITHUB_TOKEN`); with the isolation below it can be the infra job's own token, which is no worse than what
  `.git/config` already exposes.
- Large renders (CRDs for N clusters) go through `platformCommit`. In 44.239.1 that path does not send file
  contents through GraphQL: it pushes the git objects to `refs/renovate/branches/<branch>` with `git push`, then
  creates the tree with REST `POST /git/trees` from `git diff-tree` entries (blob SHAs only) and the commit with
  `POST /git/commits` (`modules/platform/github/index.js` `pushFiles`, **verified**). Payload size is then bounded
  by the number of changed files, not their size; a limit on tree entries per request is **unverified**. A pilot
  step covers it.
- Debugging happens in the runner logs of `gsuquet/renovate-bot`, not in infra.

### B. GitHub Actions workflow pushes the render to the Renovate branch

A workflow on Renovate PRs runs `mise run manifests:render` and pushes a second commit.

Facts:

- Events from `GITHUB_TOKEN` do not start new workflow runs, except `workflow_dispatch`, `repository_dispatch`, and
  `pull_request` `opened`/`synchronize`/`reopened`, which start in an approval-required state until a user with
  write access approves them ([GITHUB_TOKEN](https://docs.github.com/en/actions/concepts/security/github_token),
  **verified**). A GitHub App installation token or a PAT starts them normally
  ([Triggering a workflow from a workflow](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow),
  **verified**).
- Renovate treats a PR as modified when another git author adds to the branch, unless that author's email is in
  `gitIgnoredAuthors` ([gitIgnoredAuthors](https://docs.renovatebot.com/configuration-options/#gitignoredauthors),
  **verified**). On a modified branch Renovate stops updating it; the rebase checkbox or `rebaseLabel` makes
  Renovate regenerate its commit and discard the edits ([Updating and rebasing](https://docs.renovatebot.com/updating-rebasing/),
  **verified**).
- infra extends `:rebaseStalePrs`, which sets `rebaseWhen: behind-base-branch` (44.239.1 preset source,
  **verified**): Renovate rebases
  whenever `main` moves ([rebaseWhen](https://docs.renovatebot.com/configuration-options/#rebasewhen), **verified**
  for the value's meaning).

Design if chosen:

1. Trigger on `pull_request` (never `pull_request_target`), only for head refs under `gsuquet/renovate/` and the
   Renovate App actor.
2. Job 1, `contents: read`, no secret: render, then upload `git diff --binary` as an artifact.
3. Job 2: mint a token from a dedicated GitHub App (contents: write on `gsuquet/infra` only), check the patch
   touches only `gitops/clusters/*/rendered/**`, commit it, push. Job 2 never runs PR code.
4. Loop prevention: commit only when the diff is non-empty; job 1 on the bot's own commit finds no diff and stops.
5. Add the bot's email to `gitIgnoredAuthors`, so Renovate keeps rebasing. Each rebase drops the render commit and
   the workflow adds it again: one extra CI cycle per rebase.

Costs: a write credential in the public repo's Actions secrets (against ADR-0019), a second App to manage, two CI
runs per Renovate push, and unsigned commits unless job 2 commits through the API. The `GITHUB_TOKEN` variant
avoids the secret but needs a manual "Approve workflows to run" click on every push, and gives the PR-code job a
write token unless split as above.

### C. Manual or agent render (status quo in homelab)

A person or an agent checks out the PR, runs `mise run manifests:render`, and pushes. Free and simple, but it marks
the branch as modified (Renovate stops rebasing it), and every chart PR needs a human action before review. Keep it
as the fallback when option A reports an artifact error.

### D. Kargo or another updater

- **Kargo** **(unverified, docs.kargo.io is not in the allowed domains)**: a Warehouse can subscribe to Helm chart
  and image repositories, and promotion steps can update a chart, render, commit and open a PR. It is planned for
  tenant promotion (render -> PR to `gsuquet/gitops`). For platform components it would make a cluster manage the
  upgrades of its own platform (Kargo needs Argo CD, cert-manager and so on to be running first), and it does not
  cover mise tools, GitHub Actions or Terraform providers, so Renovate stays anyway. Not recommended for infra.
- **Updatecli** **(unverified)**: can run shell targets in a GitHub Action, but has the same token problem as
  option B and duplicates Renovate. Not recommended.

## Comparison

| Criterion | A. postUpgradeTasks | B. Actions push | C. Manual | D. Kargo |
| --- | --- | --- | --- | --- |
| Secret in infra CI | none | App key (or approval click) | none | none in CI, in-cluster creds |
| Render in the same commit | yes | second commit | second commit | n/a |
| Renovate keeps rebasing | yes | only with `gitIgnoredAuthors` | no | n/a |
| Loop risk | none | must be designed out | none | none |
| Covers mise / actions / Terraform | yes (Renovate) | yes (Renovate) | yes | no |
| Branch code runs next to a write token | yes: infra-only token (with the isolation below); every `gsuquet/*` repo without it | no: job 2 never runs branch code | on the person's machine | n/a |
| Changes outside infra | runner: separate infra job, `allowedCommands`, `allowedUnsafeExecutions`, version bump | new App | none | Kargo install |
| Human work per chart PR | review | review | render + push + review | review |

Re-weighing with the token exposure: without isolation, A is worse than B (branch code can reach a token valid for
every repo, the runner's own included). With a dedicated job and a token minted for infra only, the blast radius
of A is "write to infra", the same as B's App token, but reached through branch code instead of a job that never
runs it. B keeps a cleaner boundary; A keeps the render in Renovate's own commit (no modified branch, no second
CI cycle, no write secret in infra's Actions). A malicious render that can write to infra could already change what
infra deploys through the PR it renders, so the extra risk of A over B is small once the token is single-repo, as
long as `main` is protected by a ruleset (open question 7). A stays recommended, conditional on the isolation.

## Recommended design

Option A, with C as the fallback, and **only with the runner isolation below**. Without it, choose B.

Runner (`gsuquet/renovate-bot`):

1. Split the workflow into two jobs (same `concurrency` group so they do not overlap):
   - `renovate`: current job, current global config, plus `"autodiscoverFilter": ["gsuquet/*", "!gsuquet/infra"]`
     (negative patterns are supported by `matchRegexOrGlobList`, `util/string-match.js`, 44.239.1 source,
     **verified**). No `allowedCommands`.
   - `renovate-infra`: mints its App token with `actions/create-github-app-token` `owner: gsuquet` and
     `repositories: infra`, so the token cannot reach any other repo, `renovate-bot` included (input documented
     by the action **(unverified, the action README is outside the allowed domains)**). Runs Renovate with
     `autodiscover: false`, `repositories: ["gsuquet/infra"]`, and a second global config file that alone carries
     the options below.
2. Check the App's permissions and installation scope, notably `workflows: write` and whether `renovate-bot` is
   in the installation **(unverified)**.
3. Add `actions/cache` for the mise and Containerbase directories mounted into the container, keyed on
   `.mise/mise.lock` (paths **unverified**).

`renovate-infra` global config:

```json
{
  "allowedCommands": [
    "^mise trust --yes \\.mise/config\\.toml$",
    "^mise install$",
    "^mise run manifests:render$"
  ],
  "allowedUnsafeExecutions": ["mise"],
  "customEnvVariables": { "MISE_GITHUB_TOKEN": "{{ the infra job's token }}" }
}
```

- The anchors only keep stray commands out; they are not a security control (see option A costs).
- `customEnvVariables` is global-only (44.239.1 `config/options`, **verified**). The token value is set from the
  workflow (environment variable or generated config file), never committed. The exact wiring through
  `renovatebot/github-action` is **unverified**; the env var name mise reads is **unverified**.
- Bump the runner from 41.115.2 to a version that accepts `allowedUnsafeExecutions` (44.239.1 does, **verified**;
  the first version that does is **unverified**). Pin it like everything else.
- Keep `binarySource=install` (default) so `installTools` works.

Repo (`.github/renovate.json`), on top of what exists:

```json
{
  "ignorePaths": [
    "**/node_modules/**",
    "**/bower_components/**",
    "**/vendor/**",
    "**/examples/**",
    "**/__tests__/**",
    "**/test/**",
    "**/tests/**",
    "**/__fixtures__/**",
    "gitops/clusters/*/rendered/**"
  ],
  "packageRules": [
    {
      "description": "Render tools get their own group, so every upgrade of that branch carries the render task",
      "groupName": "render tools",
      "groupSlug": "render-tools",
      "matchDepNames": ["helm", "kustomize", "yq"],
      "matchManagers": ["mise"],
      "semanticCommitScope": "tools"
    },
    {
      "description": "Branches whose every upgrade can change the render output re-render in the same commit",
      "matchFileNames": ["gitops/components/**"],
      "postUpgradeTasks": {
        "installTools": { "mise": {} },
        "commands": [
          "mise trust --yes .mise/config.toml",
          "mise install",
          "mise run manifests:render"
        ],
        "fileFilters": ["gitops/clusters/*/rendered/**"],
        "executionMode": "branch"
      }
    },
    {
      "description": "Same task for the render tools group",
      "matchDepNames": ["helm", "kustomize", "yq"],
      "matchManagers": ["mise"],
      "postUpgradeTasks": {
        "installTools": { "mise": {} },
        "commands": [
          "mise trust --yes .mise/config.toml",
          "mise install",
          "mise run manifests:render"
        ],
        "fileFilters": ["gitops/clusters/*/rendered/**"],
        "executionMode": "branch"
      }
    }
  ]
}
```

This repo snippet passes `renovate-config-validator --strict` 44.239.1 **(verified)**. The full flow (tools install,
render, commit of added and deleted files) is **unverified** until a pilot run.

- `ignorePaths` is `mergeable: false` (44.239.1 `config/options`, **verified**): a repo value replaces the list
  from `config:best-practices` (`:ignoreModulesAndTests`) instead of extending it. The snippet repeats the preset's
  paths (44.239.1 `default.preset.js`, **verified**) so test and fixture directories stay ignored. Re-check the
  list when the preset changes.
- Every branch that gets the task must consist only of matching upgrades (see the `executionMode` caveat). The
  `render tools` group takes helm, kustomize and yq out of `dev tools` (the later rule wins for `groupName`), so
  `dev tools` never needs a render and `render tools` always gets one. Chart groups are scoped to
  `gitops/components/<name>/**` (see [Grouping](#grouping)), so every upgrade in them matches the first task rule.
  Do not add a group that mixes component files with anything else.
- The `matchDepNames` list must follow the tools the render actually uses; add a tool there when the render task
  starts using it.
- `fileFilters` limits the commit to rendered files: a render that rewrites anything else is dropped, and
  `manifests:check` catches it.
- Rendering every cluster is fine: the render is deterministic and the check renders everything anyway.
- Terraform providers, GitHub Actions and the other `dev tools` do not render.

### Grouping

- Keep the existing groups (`dev tools`, `terraform cli`, `terraform providers`) and the weekly schedule.
- Charts: one PR per component by default (Renovate's default branch per dependency). Group a chart with the image
  tags of the same component when both are pinned (one rule per component with `matchFileNames:
  ["gitops/components/<name>/**"]` and `groupName: "<name>"`), or drop image tags from default values.
- Coupled components get one group: `gateway-api-crds` with any Gateway API implementation that requires a given
  CRD version, `cert-manager` with its CRDs if split.
- Majors keep `dependencyDashboardApproval`.
- Semantic scope `gitops` (or `component`) for `gitops/**`, as homelab used `kubernetes`.

### Bootstrap coupling

Terraform installs Cilium, the Gateway API CRDs and Argo CD from `rendered/` (bootstrap boundary). If the bootstrap
modules read `gitops/clusters/<name>/rendered/<component>/` and pin no version of their own, a chart PR updates the
bootstrap input too and there is one version per component. If a module pins its own chart version, Renovate opens
a second PR for the same component and the two can drift.

### Pilot

1. Bump the runner, split out the `renovate-infra` job with its single-repo token, and add the global options to
   that job only. Check from a throwaway task that the token in `.git/config` is rejected by another repo.
2. Add the repo rules once the render task and one component exist.
3. Force a chart bump with a manual run (`workflow_dispatch`, `dry_run: off`) and check: tools installed, render
   committed in Renovate's commit, deleted files removed, `manifests:check` green.
4. Force a mixed weekly run: a `helm` (render tools) bump together with an `actions/checkout` (dev tools) bump.
   Check that `render tools` re-renders and `dev tools` carries no render.
5. Force a large bump that rewrites CRDs in every cluster (for example cert-manager or Argo CD across a major
   version) and check the platform commit goes through.
6. Check the Renovate commit is still signed (`platformCommit: enabled`) with the rendered files in it, and that
   two consecutive runs hit the cache and no GitHub rate limit.

## Local checks

Done for this study, with the Renovate binaries in the pre-commit cache:

- `renovate --platform=local --dry-run=extract` (44.239.1) on a scratch repo with an umbrella `Chart.yaml`, a
  `component.yaml`, `values.yaml` files, a `rendered/` file and `.mise/config.toml`: results in the manager table.
- `renovate-config-validator --strict` (44.239.1) on the repo rules above and on the global options: pass.
- `renovate-config-validator --strict` (41.115.2) on the global options: fails on `allowedUnsafeExecutions`.

## Open questions

1. Component shape: umbrella `Chart.yaml` (recommended, native `helmv3`) or a custom `component.yaml` with a regex
   manager? This also settles whether `Chart.lock` is committed.
2. Is "branch code can write to infra" acceptable with the single-repo token (option A), or is B's stricter
   boundary worth a write secret in infra's Actions and a second CI cycle per push? Either way, confirm the App's
   permissions (`workflows: write`?) and whether `gsuquet/renovate-bot` is in its installation.
3. Bump the runner from 41.115.2 now? `mise.lock` refresh needs it regardless of this study.
4. Pin image tags in component default values, or let charts own them?
5. Forbid chart and image version overrides in `cluster.yaml` (schema rule), so one version lives in the catalog?
6. Should the Kargo pipeline for tenants (render -> PR to `gsuquet/gitops`) reuse the same render task, so one
   implementation renders both?
7. Should `manifests:check` become a required status check on `main` (no ruleset exists today)? Without it a stale
   render can be merged by mistake. A ruleset on `main` also stops the infra-scoped Renovate token (readable by the
   render, see option A) from pushing to `main` directly.
