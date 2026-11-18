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
| Public repo, CI must hold no secret ([ADR-0019](../adr/0019-lifecycle-tasks-and-ci-scope.md) driver: "No credential in CI for this public repository"). | Any option that needs a write token in infra's CI goes against an accepted ADR. |
| The owner self-hosts Renovate: `gsuquet/renovate-bot` runs `renovatebot/github-action` on a schedule with a GitHub App token, `autodiscover` over `gsuquet/*`, `platformCommit: enabled`, image `ghcr.io/renovatebot/renovate:41.115.2`. | Global (admin-only) options such as `allowedCommands` are in the owner's hands. |
| Humans merge every PR. | No automerge, no `ignoreTests`. A red PR is acceptable only if the fix is obvious. |
| The render is a mise task with tool versions pinned in `.mise/config.toml` + `mise.lock`. | Whatever renders must run the same task with the same tools, or the output differs and `manifests:check` fails. |
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
  A grouped PR renders once.
- `fileFilters` default to `**/*` ([fileFilters](https://docs.renovatebot.com/configuration-options/#postupgradetasksfilefilters),
  **verified**). Deleted files are committed when they match `fileFilters` (44.239.1 source, **verified**), so a
  chart that drops a resource removes its rendered file.
- A failing command becomes an "artifact error" on the branch, not a crash (44.239.1 source, **verified**). The PR
  shows it, and `manifests:check` stays red.
- `installTools` installs Containerbase tools before the commands; `mise` and `helm` are in the list. It has no
  effect with `binarySource=global` ([installTools](https://docs.renovatebot.com/configuration-options/#postupgradetasksinstalltools),
  **verified**).
- Renovate passes only a limited set of environment variables to child processes unless `exposeAllEnv` is set
  ([exposeAllEnv](https://docs.renovatebot.com/self-hosted-configuration/#exposeallenv), **verified**).
- Refreshing `mise.lock` after a mise tool bump needs `mise` in the global `allowedUnsafeExecutions`
  ([mise manager](https://docs.renovatebot.com/modules/manager/mise/), **verified**). The validator of Renovate
  41.115.2 (the runner's version) rejects `allowedUnsafeExecutions`; 44.239.1 accepts it (local run, **verified**).
  This affects infra today, render or not: `.mise/config.toml` sets `lockfile = true`.

Because the render is part of Renovate's single commit, every Renovate rebase recomputes it. There is no extra
commit, no "modified branch", no loop, and no token in infra's CI.

Costs:

- The runner must be able to run the render: mise, then every tool the render needs (helm, yq, ...) from
  `mise.lock`, with network access to the chart repositories. The first run downloads all tools; later runs depend
  on the runner cache **(unverified)**.
- `allowedCommands` is global for every `gsuquet/*` repo the runner autodiscovers: any of them that defines
  `manifests:render` gets it run with the runner's privileges. All are the owner's repos, but the render executes
  repo-defined scripts and third-party binaries in the process that holds the Renovate App token. The token is not
  in the child environment by default (above), but a process of the same user may still read the parent's
  environment through `/proc` **(unverified for the GitHub Actions container)**. `minimumReleaseAge: 3 days` and
  `mise.lock` checksums reduce the risk of a poisoned tool.
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
| Changes outside infra | runner: `allowedCommands`, `allowedUnsafeExecutions`, version bump | new App | none | Kargo install |
| Human work per chart PR | review | review | render + push + review | review |

## Recommended design

Option A, with C as the fallback.

Runner (`gsuquet/renovate-bot`, global config):

```json
{
  "allowedCommands": [
    "^mise trust --yes \\.mise/config\\.toml$",
    "^mise install$",
    "^mise run manifests:render$"
  ],
  "allowedUnsafeExecutions": ["mise"]
}
```

- Bump the runner from 41.115.2 to a version that accepts `allowedUnsafeExecutions` (44.239.1 does, **verified**;
  the first version that does is **unverified**). Pin it like everything else.
- Keep `binarySource=install` (default) so `installTools` works.

Repo (`.github/renovate.json`), on top of what exists:

```json
{
  "ignorePaths": ["gitops/clusters/*/rendered/**"],
  "packageRules": [
    {
      "description": "Updates that can change the render output re-render in the same commit",
      "matchFileNames": ["gitops/components/**", ".mise/config.toml"],
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

This repo snippet passes `renovate-config-validator --strict` 44.239.1 **(verified)**. The full flow (tools install, render, commit of added and deleted files) is
**unverified** until a pilot run.

- `fileFilters` limits the commit to rendered files: a render that rewrites anything else is dropped, and
  `manifests:check` catches it.
- Rendering every cluster is fine: the render is deterministic and the check renders everything anyway.
- `.mise/config.toml` is in the match because a helm or yq bump can change the output. It puts the render task on
  the `dev tools` group branch too.
- Terraform providers and GitHub Actions do not render.

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

1. Bump the runner and add the global options.
2. Add the repo rules once the render task and one component exist.
3. Force a chart bump with a manual run (`workflow_dispatch`, `dry_run: off`) and check: tools installed, render
   committed in Renovate's commit, deleted files removed, `manifests:check` green.
4. Check the Renovate commit is still signed (`platformCommit: enabled`) with the rendered files in it.

## Local checks

Done for this study, with the Renovate binaries in the pre-commit cache:

- `renovate --platform=local --dry-run=extract` (44.239.1) on a scratch repo with an umbrella `Chart.yaml`, a
  `component.yaml`, `values.yaml` files, a `rendered/` file and `.mise/config.toml`: results in the manager table.
- `renovate-config-validator --strict` (44.239.1) on the repo rules above and on the global options: pass.
- `renovate-config-validator --strict` (41.115.2) on the global options: fails on `allowedUnsafeExecutions`.

## Open questions

1. Component shape: umbrella `Chart.yaml` (recommended, native `helmv3`) or a custom `component.yaml` with a regex
   manager? This also settles whether `Chart.lock` is committed.
2. Is running repo-defined render code inside the Renovate runner, which holds an App token for every `gsuquet/*`
   repo, acceptable? Alternatives: narrow the App installation, or a separate runner job for infra only.
3. Bump the runner from 41.115.2 now? `mise.lock` refresh needs it regardless of this study.
4. Pin image tags in component default values, or let charts own them?
5. Forbid chart and image version overrides in `cluster.yaml` (schema rule), so one version lives in the catalog?
6. Should the Kargo pipeline for tenants (render -> PR to `gsuquet/gitops`) reuse the same render task, so one
   implementation renders both?
7. Should `manifests:check` become a required status check on `main` (no ruleset exists today)? Without it a stale
   render can be merged by mistake.
