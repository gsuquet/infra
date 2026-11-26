# Renovate rendered manifests: runner isolation

Changes to `gsuquet/renovate-bot` so that branch code reaches a token for infra only. It supports [RFC 0023](../rfc/0023-renovate-rendered-manifests.md), which holds the decision.

"verified" and "unverified" follow the [markers](0023-renovate-rendered-manifests-options.md#markers).

The [RFC charts](../rfc/0023-renovate-rendered-manifests.md#summary) show the jobs and tokens before and after.

| Step | Change |
| --- | --- |
| 1 | Split the workflow into `renovate` and `renovate-infra`, same `concurrency` group so they never overlap |
| 2 | `renovate`: current global config plus `"autodiscoverFilter": ["gsuquet/*", "!gsuquet/infra"]` (negation in `util/string-match.js` (verified)); no `allowedCommands` |
| 3 | `renovate-infra`: `actions/create-github-app-token` with `owner: gsuquet`, `repositories: infra` (unverified); `autodiscover: false`, `repositories: ["gsuquet/infra"]`, a second global config file that alone carries the options below |
| 4 | Check the App permissions and installation scope: `workflows: write`, and whether `renovate-bot` is installed (unverified) |
| 5 | `actions/cache` for the mise and Containerbase directories mounted into the container, keyed on `.mise/mise.lock` (paths (unverified)) |
| 6 | Bump Renovate from 41.115.2 to a pinned version that accepts `allowedUnsafeExecutions` (44.239.1 (verified); first such version (unverified)); keep `binarySource=install` |

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

- The anchors keep stray commands out; they are not a security control.
- `customEnvVariables` is global-only (verified). The value comes from the workflow (env var or generated file), never
  committed. Wiring through `renovatebot/github-action` (unverified); the env var name mise reads (unverified).
- The token gives `mise install` an authenticated GitHub API limit. Without it, `github:`, `aqua:` and `ubi:`
  backends share 60 requests per hour per runner IP (unverified): expect intermittent artifact errors.

## Token threat

Render code on a Renovate branch runs next to the Renovate token in `.git/config` of the clone, the commands' `cwd`,
readable by every post-upgrade command. `allowedCommands` is not a boundary: `mise run manifests:render` and `mise install` run whatever the
branch's task files and `.mise/config.toml` say. Any mise-installed binary, mise hook or env template (trusted by the
allowed `mise trust --yes`) can read the token (verified).

Today the token is minted with `owner: gsuquet` and no `repositories`, so it likely reaches `gsuquet/renovate-bot`,
which holds `RENOVATE_PRIVATE_KEY`. Until infra runs in its own job, a malicious render could read a token valid for
every installed repo. If the App has `workflows: write` (needed to bump actions, unverified), it could push a
workflow to `renovate-bot` that exfiltrates `RENOVATE_PRIVATE_KEY`.

What a compromised render can write to, with and without the isolation:
[Blast radius](../rfc/0023-renovate-rendered-manifests.md#operational-impact).

Controls: single-repo token with `allowedCommands` only in the infra job, App permissions checked,
`minimumReleaseAge: 3 days`, `.mise/mise.lock` checksums, review of task changes on `main`, a ruleset on `main`.
