# Renovate rendered manifests: component shape and managers

How Renovate finds each version that changes the render. It supports [RFC 0023](../rfc/0023-renovate-rendered-manifests.md), which holds the decision.

"verified" and "unverified" follow the [markers](0023-renovate-rendered-manifests-options.md#markers).

Checked with Renovate 44.239.1 `--platform=local --dry-run=extract` on a scratch repo (verified):

| Version source | Manager | Result |
| --- | --- | --- |
| Umbrella `gitops/components/<name>/Chart.yaml`, `dependencies[].version` | `helmv3`, default match `/(^\|/)Chart\.ya?ml$/` (verified) | Extracted, datasource `helm`; OCI charts use `docker` (verified) |
| Custom `component.yaml` with `chart.repository/name/version` | `custom.regex`, `datasourceTemplate: helm` | Extracted with the regex below (`cert-manager` `v1.19.1` from `https://charts.jetstack.io`) (verified) |
| Image tags in component `values.yaml`, nested keys too | `helm-values`, default match `/(^\|/)values\.ya?ml$/` (verified) | Extracted, including `argo-cd.global.image` |
| Overrides in `gitops/clusters/<name>/cluster.yaml` | none | Needs a `# renovate:` regex; better forbid overrides by schema |
| `gitops/clusters/*/rendered/**` | none | Not extracted (verified); still add to `ignorePaths` so a broad regex never bumps generated files |
| Render tools in `.mise/config.toml` | `mise`, includes `**/.mise/config{,.*}.toml` (verified) | Extracted |

Proposed shape: umbrella `Chart.yaml` per component. No custom manager, native OCI and `registryAliases` (verified),
and what homelab renders. The regex alternative is order- and indentation-sensitive and must follow the file format:

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

| Note | Status |
| --- | --- |
| A committed `Chart.lock` is updated by `helmv3` as an artifact, which needs `helm` in the Renovate environment; the helmv3 page only says lock file maintenance runs the package manager | (unverified) for artifacts |
| With `binarySource=install` (default) Renovate installs helm through Containerbase for helmv3 | (unverified) |
| A default-values image tag usually tracks the chart `appVersion`; a separate image PR can disagree with the chart PR: drop image tags or group them with the chart | design rule |
| The `mise` manager reports `skipReason: github-token-required` without a token; the App token covers it in the runner | (verified) locally, (unverified) in the runner |
