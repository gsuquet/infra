# How to render manifests

Regenerate and check `rendered/` after you change a chart, its values, a `cluster.yaml` or a tenant file, so the
pull request carries the manifests Argo CD will apply.

## Before you start

- Tools installed from the repository root: `mise install`.
- Your source change is saved: a file under `gitops/components/<name>/sources/`, a `cluster.yaml` or a tenant file.

## Steps

1. Render every cluster.

   ```sh
   mise run manifests:render
   ```

   Each cluster prints `[INFO] Rendering cluster <root>/clusters/<cluster>`, then `[INFO]   rendered <component>`
   per component.

2. Review what changed in `rendered/`.

   ```sh
   git status --short -- '*/rendered/*'
   git diff -- '*/rendered/*'
   ```

   Only the resources your source change should touch appear.

3. Validate the output.

   ```sh
   mise run manifests:validate
   mise run policy:check
   ```

   `[INFO] 1 cluster(s) valid` per root, then `0 failures`.

4. Commit the source change and `rendered/` in the same commit.

## Verify

```sh
mise run manifests:check
```

Expected last line: `[INFO] The rendered manifests are up to date`. CI runs the same check on the pull request.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `manifests:check` fails right after a render | a chart generates random values (passwords, self-signed certificates) | set the value in the component values, or produce it in the cluster with External Secrets or cert-manager |
| render fails on a duplicate file name | two resources map to the same `<kind>-<name>.yaml` | rename one resource in the chart values |
| a ServiceMonitor or HTTPRoute is missing | its template is gated on `.Capabilities.APIVersions` | add the API to `apiVersions` in `cluster.yaml` |
| kubeconform: no schema for a custom resource | its CRD is not rendered on the same cluster | enable the component that ships the CRD, or commit `schemas/crds/<group>/<kind>_<version>.json` |

## Related

- [Rendered manifests](../concepts/rendered-manifests.md)
- [GitOps tooling reference](../reference/gitops-tooling.md)
