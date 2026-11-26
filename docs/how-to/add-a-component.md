# How to add a component

Add a Helm chart to the catalog and enable it on the clusters that need it.

## Before you start

- Tools installed from the repository root: `mise install`.
- The upstream chart, its repository and the version to pin.
- The namespace the component runs in, and the targets (`kind`, `talos`, `gke`) it supports.

## Steps

1. Create the catalog entry `gitops/components/<name>/component.yaml` (fields:
   [GitOps files](../reference/gitops-files.md#component-gitopscomponentsnamecomponentyaml)) and the umbrella chart
   in `gitops/components/<name>/sources/`: `Chart.yaml` with the upstream chart as a dependency, `values.yaml`
   with the defaults. Set every value a chart would otherwise generate at template time (certificates,
   passwords). (untested)

2. Lock the chart version and commit `Chart.lock` (`charts/*.tgz` is ignored by Git). (untested)

   ```sh
   helm dependency update gitops/components/<name>/sources
   ```

   `Chart.lock` lists the pinned version.

3. Add `- name: <name>` to `components` in each `gitops/clusters/<cluster>/cluster.yaml` that needs it, with
   `values` overrides when the cluster differs from the defaults.

4. Render and review the new `rendered/<name>/` folders: follow [How to render manifests](render-manifests.md).

5. Run the checks.

   ```sh
   mise run schemas:check
   mise run manifests:validate
   mise run policy:check
   ```

   Every task exits 0.

## Verify

```sh
mise run manifests:check
```

Expected last line: `[INFO] The rendered manifests are up to date`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `schemas:check`: component not supported | the cluster's `target` is not in `targets` | remove it from that cluster, or add the target if it works there |
| `policy:check`: Namespace without the policy label | the chart or Argo CD creates the namespace at runtime | render a `Namespace` with `network.infra.gsuquet.com/policy: default-deny` |
| `policy:check`: Gateway API CRD outside `gateway-api-crds` | the implementation chart bundles the CRDs | disable its CRD installation in `values.yaml` |
| traffic blocked after sync | the cluster-wide default deny | add the component's allow rules to the `network-policy` component (planned) |

## Related

- [Rendered manifests](../concepts/rendered-manifests.md),
  [Baseline components](../reference/gitops-files.md#baseline-components)
- [GitOps tooling reference](../reference/gitops-tooling.md)
