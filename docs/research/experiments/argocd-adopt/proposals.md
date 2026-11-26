# Proposals from the argocd-adopt experiment

Back to the [experiment summary](../argocd-adopt.md).

These are inputs for RFCs, not decisions.

## Points against accepted ADRs

| ADR | What it says | Result or proposal here |
|---|---|---|
| [ADR-0015](https://github.com/gsuquet/infra/blob/main/docs/adr/0015-bootstrap-boundary.md) | Argo CD is the single long-term owner of every in-cluster resource | Argo CD never [owns a CRD](crds.md) |
| [ADR-0012](https://github.com/gsuquet/infra/blob/main/docs/adr/0012-gateway-api-crd-ownership.md) | CRD upgrades are a single, explicit pull request | [Removing a CRD](crds.md#a-crd-removed-from-git-is-orphaned) needs a manual step |
| [ADR-0012](https://github.com/gsuquet/infra/blob/main/docs/adr/0012-gateway-api-crd-ownership.md) | TCPRoute and UDPRoute are experimental | They are in the [standard channel](crds.md#tcproute-and-udproute-are-in-the-standard-channel) |
| [ADR-0004](https://github.com/gsuquet/infra/blob/main/docs/adr/0004-self-managed-argo-cd-per-cluster.md) | A broken self-update needs a manual re-apply of `rendered/argocd/` (the bootstrap module applies the same files) | A one-shot apply keyed on the cluster ID does not run again; a [re-apply](field-managers.md#stale-re-apply) is accepted silently |
| [ADR-0015](https://github.com/gsuquet/infra/blob/main/docs/adr/0015-bootstrap-boundary.md) | `bootstrap-argocd` installs Argo CD and its root `Application` | Proposal: moving the children out of the `argocd` Application changes that layout |

Whether these ADRs are amended is [open](../argocd-adopt.md#open-questions).

## Tracking method

`annotation` (the Argo CD 3.x default). Set it explicitly in `argocd-cm`. The rendered
files do not need a pre-set tracking annotation: the first sync adds it with no rollout.
The only side effect is a Deployment generation +1. CRDs are the exception: Argo CD
never annotates them ([source](crds.md#argo-cd-applies-crds-but-never-tracks-them)).

## Sync options

Only server-side apply with server-side diff was run; the first two items are
recommendations, not compared with a control:
- `ServerSideApply=true` on every Application (tested configuration, no control run with
  client-side apply). Reasons from the docs, not from this run: the large CRDs hit the
  262144-byte annotation limit of client-side apply, and Argo CD applies with
  `--force-conflicts`
  ([docs](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#server-side-apply)),
  so it always wins a conflict.
- `controller.diff.server.side: true` (tested configuration, no control run with
  client-side diff). With it, no OutOfSync loop was seen; whether the client-side diff
  would loop on defaulted fields is not tested.
- **`Replace=true`: not needed** for any CRD here. Avoid it: it takes precedence over
  server-side apply, uses `kubectl replace/create`, and the docs warn it can recreate
  resources
  ([docs](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#replace-resource-instead-of-applying-changes)).
- **Proposal for the plan** (not in the settled plan): `Prune=false` on CRDs is
  **redundant** with Argo CD v3.5: the [CRD removal
  check](crds.md#a-crd-removed-from-git-is-orphaned) shows a CRD removed from Git is not
  pruned without it, and the source shows CRDs are never tracked, so never pruned and
  never cascade-deleted. Keep it only as cheap insurance against a future Argo CD change
  (the argo-cd chart already sets it on its own CRDs). `Prune=false,Delete=false` on the
  `argocd` Namespace and `argocd-secret` stays a proposal, not tested here.
- **Removing a CRD is a manual step, and must be detected.** A Gateway API bundle
  upgrade that drops a CRD leaves it in the cluster with every Application `Synced`. The
  plan needs a check that compares the live CRDs of each component with its rendered
  files (for example in `manifests:check` or a cluster audit), and a runbook step to
  delete them.
- `PrunePropagationPolicy`: no effect on adoption (nothing is pruned). Keep the default
  (`foreground`, per the
  [docs](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#resources-prune-deletion-propagation-policy)).

## Field manager

**Field manager: Terraform must apply as `argocd-controller`.** Else every field removed
from Git later stays in the cluster with a `Synced` status
([evidence](field-managers.md#field-removal)). This matches the homelab
`bootstrap-argocd` module, and the plan must make it the rule for all three bootstrap
modules (`bootstrap-gateway-api`, `bootstrap-cilium`, `bootstrap-argocd`), not only Argo
CD.

## Bootstrap apply

**Terraform must not apply again.** With the shared manager a re-apply silently
downgrades ([evidence](field-managers.md#stale-re-apply)). That check tested only a
stale update of an existing object, not Terraform's create and destroy paths. Options:
- `kubectl_manifest` per document with `server_side_apply = true`, `field_manager =
  "argocd-controller"` and `lifecycle { ignore_changes = all }` (the homelab design).
  `ignore_changes` only stops in-place updates. It does not stop:
  - **re-creation**: an object gone from the cluster (deleted by Argo CD, by a TTL, by
    hand) leaves the state on refresh, and the next apply creates it again, without the
    tracking annotation;
  - **create and destroy on key changes**: the `for_each` keys come from the rendered
    files at the checked-out HEAD. A plan or apply from a feature branch, or after a
    merge that adds or removes a document, creates objects from unmerged or newer
    renders (Argo CD does not track them until a sync) or destroys objects that left the
    render (Argo CD may still want them);
  - `terraform destroy` on the root deletes them (acceptable: a cluster root destroys
    the cluster anyway); `alekc/kubectl` 3.x has `apply_only` to skip the delete (docs
    only, not tested);
  - a provider upgrade that changes the schema can plan a replace.
- Pin the bootstrap input to a fixed snapshot instead of HEAD (a copy of
  `rendered/{gateway-api-crds,cilium,argocd}` made at cluster creation, or a Git ref in
  a variable). The key set then stops moving with `main`; the re-create risk stays.
- A one-shot apply (`terraform_data` + `local-exec` `kubectl apply --server-side
  --field-manager=argocd-controller`, triggered by the cluster ID). No Kubernetes object
  in the state, so no drift, no re-create and no key-set churn; but a `kubectl`
  dependency on the runner and no plan output.

No recommendation until a Terraform run (`mise run cluster:up` twice, once after a
render change and once after Argo CD deleted a bootstrap object) compares the options.
Leaning: the one-shot apply, since the bootstrap is by design a one-time hand-over.

### Recovery of a broken Argo CD

[ADR-0004](https://github.com/gsuquet/infra/blob/main/docs/adr/0004-self-managed-argo-cd-per-cluster.md)
recovers with a manual re-apply of `rendered/argocd/`. No option was run for this; the
points below are reasoning:

- `ignore_changes = all`: updates to existing objects are ignored, so `terraform apply`
  repairs only deleted objects; a changed object needs a manual re-apply.
- Pinned snapshot: the bootstrap input is a copy or a Git ref that does not move with
  `main`, so it can hold an older Argo CD than the wanted one: take the re-apply from
  the wanted Git revision instead.
- One-shot apply keyed on the cluster ID: it does not run again, so recovery needs a
  manual `kubectl apply` or a replace of the `terraform_data` resource.
- A manual re-apply as `argocd-controller` is accepted with no warning: apply the files
  of the wanted Git revision, because a stale copy downgrades Argo CD.

## Hubble TLS

**Cilium must not use `hubble.tls.auto.method=helm`** with rendered manifests: the
render is not reproducible. Use `certmanager` (cert-manager is a baseline component, but
it comes after Cilium) or `cronJob`, or keep Hubble TLS off in the bootstrap and turn it
on later. To decide in the Cilium component.

## Helm hooks

**Helm hooks are fine for Argo CD, not for `kubectl_manifest`.** Argo CD runs the chart
hooks as `PreSync` hooks. Under `kubectl_manifest` + `ignore_changes = all`, the hook
Job deletes itself after 60 s (`ttlSecondsAfterFinished`), so every later `mise run
cluster:up` would re-create it and run it again as a plain Job. The homelab trick is
therefore required with that option: apply a renamed copy without the hook annotations
and without the TTL (homelab `modules/bootstrap-argocd/main.tf`), or drop the hook
resources from the bootstrap set and let Argo CD's first sync run them. The one-shot
apply needs neither. Not tested with Terraform.

## Sync wave of CRDs

**Generic render rule:** every CRD gets `argocd.argoproj.io/sync-wave: "-1"` (done here
with one `yq` expression over all files). Kept for the plan.

## Self-sync of the app of apps

Do not rely on "Argo CD syncs itself only when `rendered/argocd/` changes"
([evidence](self-sync.md#what-the-watch-shows): 2 of 2 defaults attempts, 0 of 2 other
configurations). Each such sync re-runs the Redis secret PreSync Job (idempotent,
observed harmless here). Candidate fixes, none tested: an `ignoreDifferences` on the
`operation` field of child Applications in the `argocd` Application, or moving the child
Applications out of the `argocd` Application. `manifest-generate-paths` is [not proven
as a fix](self-sync.md#why-the-other-runs-did-not-sync).
