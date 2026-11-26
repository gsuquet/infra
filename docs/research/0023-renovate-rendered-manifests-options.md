# Renovate rendered manifests: options

Options to put the render in a Renovate PR, with the evidence for each. It supports [RFC 0023](../rfc/0023-renovate-rendered-manifests.md), which holds the decision.

## Markers

"verified" was checked on 2026-11-18 against docs.renovatebot.com, docs.github.com, the Renovate 44.239.1
source or a local run; "unverified" must be checked before building on it.

## Option A: Renovate postUpgradeTasks, self-hosted

Renovate runs the render after it updates files and before it commits, and adds the files matching `fileFilters` to
its own commit (verified).

- Good: render in Renovate's single commit; every rebase recomputes it; no modified branch, no loop, no secret in
  infra's CI.
- Good: covers every update kind, since Renovate stays the updater.
- Bad: branch code can read the Renovate token (verified), see the [token threat](0023-renovate-rendered-manifests-runner.md#token-threat).
  Acceptable only with the [`renovate-infra` job isolation](0023-renovate-rendered-manifests-runner.md).
- Bad: needs runner changes (separate job, global options, Renovate bump) and debugging moves to the runner logs.

## Option B: GitHub Actions workflow pushes the render to the Renovate branch

A workflow on Renovate PRs renders and pushes a second commit with a dedicated App token. Design if chosen:

1. Trigger on `pull_request` (never `pull_request_target`) for head refs under `gsuquet/renovate/` and the Renovate
   App actor.
2. Job 1, `contents: read`, no secret: render, upload `git diff --binary`.
3. Job 2 mints a dedicated App token (contents: write on infra only), checks the patch touches only
   `gitops/clusters/*/rendered/**`, commits through the API (signed), no git push; it never runs PR code.
4. Commit only on a non-empty diff, so job 1 on the bot's own commit stops.
5. Bot email in `gitIgnoredAuthors`; each rebase costs one extra CI cycle (`:rebaseStalePrs` sets
   `rebaseWhen: behind-base-branch` (verified)).

The `GITHUB_TOKEN` variant avoids the secret but needs an approval click per push, and hands the PR-code job a write
token unless split as above.

- Good: cleanest boundary: the job that holds the write token never runs branch code.
- Bad: a write credential in the public repo's Actions secrets, against ADR-0019, and a second App to manage.
- Bad: second commit: two CI runs per Renovate push, `gitIgnoredAuthors` needed, loop prevention to design, and
  unsigned commits unless the job commits through the API.

## Option C: Kargo or Updatecli

Kargo Warehouses watch charts and images and promotion steps render and open PRs (unverified); Updatecli runs shell
targets in an Action (unverified).

- Good: Kargo is already planned for tenant promotion (RFC 0021).
- Bad: Kargo makes a cluster upgrade its own platform (it needs Argo CD, cert-manager first) and covers no mise
  tools, actions or providers, so Renovate stays anyway. Updatecli has the token problem of [option B](#option-b-github-actions-workflow-pushes-the-render-to-the-renovate-branch) and duplicates Renovate.

## Do nothing

Manual or agent render, as in [homelab](../rfc/0023-renovate-rendered-manifests.md#context): check out the PR, `mise run manifests:render`, push.

- Good: free, simple, no token near branch code except on the person's machine.
- Bad: a human action on every chart PR, and the branch becomes modified so Renovate stops rebasing it; ticking
  rebase or `rebaseLabel` regenerates Renovate's commit and discards the manual render commit (verified).

## Comparison

| Criterion | A. postUpgradeTasks | B. Actions push | C. Kargo / Updatecli | Do nothing |
| --- | --- | --- | --- | --- |
| Secret in infra CI | none | App key (or approval click) | Kargo: in-cluster creds; Updatecli: write secret like B | none |
| Render in the same commit | yes | second commit | n/a | second commit |
| Renovate keeps rebasing | yes | only with `gitIgnoredAuthors` | n/a | no |
| Loop risk | none | must be designed out | none | none |
| Covers mise, actions, providers | yes | yes | no | yes |
| Branch code next to a write token | infra-only token with isolation; every `gsuquet/*` repo without | no | n/a | on the person's machine |
| Changes outside infra | runner job split, global options, version bump | new App | Kargo install | none |
| Human work per chart PR | review | review | review | render, push, review |

## Weighing

Without isolation, [option A](#option-a-renovate-postupgradetasks-self-hosted) is worse than [option B](#option-b-github-actions-workflow-pushes-the-render-to-the-renovate-branch). With a single-repo token, the blast radius of [option A](#option-a-renovate-postupgradetasks-self-hosted) equals the one of [option B](#option-b-github-actions-workflow-pushes-the-render-to-the-renovate-branch) ("write to
infra") but is reached through branch code. A render that can write to infra could already change what infra
deploys through the PR it renders, so the extra risk of [option A](#option-a-renovate-postupgradetasks-self-hosted) is small once `main` has a ruleset ([Required check](../rfc/0023-renovate-rendered-manifests.md#open-questions)).

## Constraints

| Constraint | Consequence |
| --- | --- |
| Public repo, no credential in CI ([ADR-0019](../adr/0019-lifecycle-tasks-and-ci-scope.md)) | A write token in infra's CI goes against an accepted ADR |
| Owner self-hosts Renovate: `gsuquet/renovate-bot` runs `renovatebot/github-action` on a schedule, GitHub App token, `autodiscover` over `gsuquet/*`, `platformCommit: enabled`, Renovate 41.115.2 | Global (admin-only) options such as `allowedCommands` are in the owner's hands |
| Humans merge every PR | No automerge, no `ignoreTests`; a red PR is fine only when the fix is obvious |
| Render tools pinned in `.mise/config.toml` + `.mise/mise.lock` | Whatever renders runs the same task with the same tools, or `manifests:check` fails |
| Tool, action and provider bumps do not touch `gitops/`, except render tools | Only some update kinds need a render |
