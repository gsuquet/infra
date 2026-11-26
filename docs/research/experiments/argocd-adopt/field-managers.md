# Field manager results

Back to the [experiment summary](../argocd-adopt.md).

## Field removal

Git removes the key `b` from both probe ConfigMaps. Argo CD reports `Synced` for both,
but only one lost the key (3 of 3 runs):

```text
probe-kubectl data: {"a":"kept","b":"removed-in-git"}
  kubectl Apply
  argocd-controller Apply
probe-argocd data: {"a":"kept"}
  argocd-controller Apply
probe app sync status: Synced
```

With a bootstrap manager other than `argocd-controller`, the bootstrap manager keeps
co-ownership of every field forever. A field that Git removes stays in the cluster, and
Argo CD shows `Synced` (the server-side diff sees no change, because the field is not
Argo CD's to remove). This drift is silent.

Argo CD's [client-side apply
migration](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#client-side-apply-migration)
does not help here: it moves only managers with `operation: Update` (client-side apply).
A server-side bootstrap creates `operation: Apply` entries.

## Stale re-apply

This dry-run shows what happens if Terraform applies the v1 files again after the
upgrade (`kubectl apply --server-side --dry-run=server` of the v1 `argocd-server`
Deployment). Same output in the six first runs and in the 3 re-runs:

```text
- field manager 'kubectl' (alekc/kubectl kubectl_manifest default), no force-conflicts:
  error: Apply failed with 6 conflicts: conflicts with "argocd-controller":
  - .metadata.labels.app.kubernetes.io/version
  - .metadata.labels.helm.sh/chart
  - .spec.template.metadata.annotations.checksum/cmd-params
  - .spec.template.metadata.labels.app.kubernetes.io/version
  - .spec.template.metadata.labels.helm.sh/chart
- field manager 'argocd-controller' (same as Argo CD):
  accepted, image would become quay.io/argoproj/argocd:v3.5.6
```

The field manager depends on the Terraform provider. `alekc/kubectl` `kubectl_manifest`
(the homelab module, pinned there at 2.2.0) has `field_manager`, default `kubectl`, and
`server_side_apply` ([registry docs,
3.0.1](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/resources/kubectl_manifest)).
`hashicorp/kubernetes` `kubernetes_manifest` has a `field_manager { name }` block
([registry docs,
3.5.0](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest));
its default name (`Terraform`) is not on that page: unverified. The
[proposals](proposals.md) assume `kubectl_manifest` with `field_manager =
"argocd-controller"` and `server_side_apply = true`.

With the shared manager, a re-apply is accepted with no warning and **downgrades Argo
CD**, until `selfHeal` puts the Git version back (another rollout). With a separate
manager it fails on conflicts, and `force_conflicts` would take the fields away from
Argo CD. So a second apply is wrong in both cases.
