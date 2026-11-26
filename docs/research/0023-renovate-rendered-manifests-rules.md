# Renovate rendered manifests: repository rules

The `.github/renovate.json` rules, the grouping and the bootstrap coupling. It supports [RFC 0023](../rfc/0023-renovate-rendered-manifests.md), which holds the decision.

"verified" and "unverified" follow the [markers](0023-renovate-rendered-manifests-options.md#markers).

## Rules

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

Passes `renovate-config-validator --strict` 44.239.1 (verified); the full flow (install, render, commit of added and
deleted files) is (unverified) until the pilot.

| Rule | Why |
| --- | --- |
| `ignorePaths` repeats the `:ignoreModulesAndTests` paths | `mergeable: false` (verified): a repo value replaces the preset list; re-check when the preset changes |
| Every branch with the task holds only matching upgrades | the [branch-mode fact](0023-renovate-rendered-manifests-tasks.md) |
| `render tools` takes helm, kustomize, yq out of `dev tools` | the later rule wins for `groupName`: `dev tools` never renders, `render tools` always does |
| `matchDepNames` follows the tools the render uses | add a tool when the render task starts using it |
| `fileFilters` limits the commit to `rendered/` | a render that rewrites anything else is dropped and `manifests:check` catches it |
| Render every cluster | the render is deterministic and the check renders everything anyway |
| Providers, actions and other `dev tools` do not render | they do not touch `gitops/` |

## Grouping

| Updates | Rule |
| --- | --- |
| Existing groups `dev tools` and the IaC groups (today `terraform cli`, `terraform providers`; renamed with RFC 0022) | Keep, with the weekly schedule |
| Charts | One PR per component (default); group chart and image tags of a component when both are pinned (`matchFileNames: ["gitops/components/<name>/**"]`, `groupName: "<name>"`), or drop image tags |
| Coupled components | One group: `gateway-api-crds` with the Gateway API implementation that needs its CRD version; `cert-manager` with its CRDs if split |
| Mixed groups | Never mix component files with anything else in one group |
| Majors | Keep `dependencyDashboardApproval` |
| Semantic scope | `gitops` (or `component`) for `gitops/**` |

## Bootstrap coupling

IaC installs Cilium, the Gateway API CRDs and Argo CD from `rendered/` (ADR-0015). When the bootstrap modules read
`gitops/clusters/<name>/rendered/<component>/` and pin no chart version of their own, one chart PR updates both and
one version exists per component. A module that pins its own version gets a second Renovate PR that can drift.
