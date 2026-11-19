# How to onboard a tenant

Give a tenant namespaces, a quota and a sync source on one or more clusters, through an `infra` pull request.

## Before you start

- Tools installed from the repository root: `mise install`.
- The tenant name (not `default` nor `platform`), its namespaces (`<tenant>` or `<tenant>-*`), its quota and
  container defaults.
- The clusters that host it.

## Steps

1. Create `gitops/tenants/<tenant>.yaml`, starting with
   `# yaml-language-server: $schema=../../schemas/tenant.schema.json` (fields:
   [GitOps files](../reference/gitops-files.md#tenant-gitopstenantstenantyaml)).

2. Add `<tenant>` to `tenants` in each `gitops/clusters/<cluster>/cluster.yaml` that hosts it.

3. Check the files.

   ```sh
   mise run schemas:check
   ```

   Exits 0.

4. Render and review: follow [How to render manifests](render-manifests.md). The diff shows, per namespace, a
   `Namespace`, a `ResourceQuota`, a `LimitRange` and a `SecretStore` named `secrets`, plus one `AppProject` and
   one `Application` per cluster.

5. (planned) Create `tenants/<tenant>/<cluster>/` in `gsuquet/gitops` and the tenant's Kargo promotion with
   git-only steps; the `Application` syncs that folder after merge.

## Verify

```sh
mise run policy:check
```

Expected: `0 failures`. After merge, the tenant `Application` is `Synced` in the cluster's Argo CD (planned).

## Undo

Remove `<tenant>` from each `cluster.yaml`, delete the tenant file, render, and merge. When the platform
`Application` prunes, Argo CD then deletes the tenant namespaces and every workload in them (untested).

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `schemas:check`: tenant namespace rejected | it is not `<tenant>` or `<tenant>-*`, starts with `kube-`, or is a component namespace | rename the namespace |
| `schemas:check`: tenant has no file | `cluster.yaml` lists a tenant without `gitops/tenants/<tenant>.yaml` | add the file or fix the name |
| tenant pod rejected at admission | Pod Security `restricted` | rebuild the image to run as non-root without extra capabilities; `baseline` only by exception, through an `infra` pull request |
| tenant workload cannot reach a Gateway or a database | the default deny; tenant allow rules are not designed yet | ask the platform owner |

## Related

- [Tenant onboarding and isolation](../concepts/tenant-isolation.md)
- [GitOps files reference](../reference/gitops-files.md)
