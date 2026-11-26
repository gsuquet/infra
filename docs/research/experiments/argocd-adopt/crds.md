# CRD results

Back to the [experiment summary](../argocd-adopt.md).

## Argo CD applies CRDs but never tracks them

This is by design, not a probe bug. Checked on `httproutes.gateway.networking.k8s.io`
and `applications.argoproj.io`, 3 of 3 runs: no `argocd.argoproj.io/tracking-id` after
adoption and after a sync that changed the CRD:

```text
crd/httproutes:
crd/applications:
crd/httproutes after adoption:
  annotations: api-approved.kubernetes.io, argocd.argoproj.io/sync-wave, gateway.networking.k8s.io/bundle-version, gateway.networking.k8s.io/channel
  labels:
  manager: argocd-controller Apply 2026-11-19T07:33:16Z
  manager: kube-apiserver Update 2026-11-19T07:33:16Z
  status in the Application: Synced
[...]
crd/httproutes after a CRD change in git:
  annotations: api-approved.kubernetes.io, argocd.argoproj.io/sync-wave, gateway.networking.k8s.io/bundle-version, gateway.networking.k8s.io/channel
  labels: exp.invalid/rev
  manager: argocd-controller Apply 2026-11-19T07:40:09Z
  manager: kube-apiserver Update 2026-11-19T07:33:16Z
  tracking-id:
```

(Timestamps from the first attempt of the defaults run, see [What
failed](limits.md#what-failed). The kept defaults run has `07:45:12Z` and `07:51:53Z`,
per the [re-run
review](https://github.com/gsuquet/infra/pull/13#issuecomment-7003896433).) **Cause,
from the Argo CD v3.5.6 source:**
- The repo-server adds the tracking annotation to every generated manifest except CRDs:
  `if q.AppLabelKey != "" && q.AppName != "" && !kube.IsCRD(target)`
  ([`reposerver/repository/repository.go#L1807`](https://github.com/argoproj/argo-cd/blob/v3.5.6/reposerver/repository/repository.go#L1807)).
  So the target object that Argo CD applies has no annotation, and the live CRD never
  gets one.
- The diff normalizer skips CRDs with the comment "CRDs don't get tracking annotations"
  ([`util/argo/resource_tracking.go#L279`](https://github.com/argoproj/argo-cd/blob/v3.5.6/util/argo/resource_tracking.go#L279),
  added by [argo-cd#22722](https://github.com/argoproj/argo-cd/pull/22722): "CRDs should
  not have resource annotations set on them").
- A live object belongs to an Application only if its tracking says so
  ([`controller/cache/cache.go#L734`](https://github.com/argoproj/argo-cd/blob/v3.5.6/controller/cache/cache.go#L734)).
  Objects that are in Git are added by name on top of that
  ([`gitops-engine/pkg/cache/cluster.go#L1554`](https://github.com/argoproj/argo-cd/blob/v3.5.6/gitops-engine/pkg/cache/cluster.go#L1554),
  "but are simply missing our label"). That is why a CRD in Git shows `Synced` and gets
  applied, while a CRD no longer in Git is invisible.
- Deleting an Application never deletes its CRDs either: `shouldBeDeleted` returns false
  for every CRD
  ([`controller/appcontroller.go#L1339`](https://github.com/argoproj/argo-cd/blob/v3.5.6/controller/appcontroller.go#L1339)).
  Read in the source, not run.
- The resource tracking docs do not mention this.

The sync result message `CRD is healthy` (other kinds: `serverside-applied`) is not a
sign of a skipped apply: it is the message of the CRD health check
([`resource_customizations/apiextensions.k8s.io/CustomResourceDefinition/health.lua`](https://github.com/argoproj/argo-cd/blob/v3.5.6/resource_customizations/apiextensions.k8s.io/CustomResourceDefinition/health.lua)),
which replaces the apply message of a task while the sync waits for its health
([`gitops-engine/pkg/sync/sync_context.go#L564`](https://github.com/argoproj/argo-cd/blob/v3.5.6/gitops-engine/pkg/sync/sync_context.go#L564)).
The new label after the CRD change and the new `argocd-controller Apply` timestamp show
that Argo CD applied it.

## A CRD removed from Git is orphaned

It is not pruned and not reported (3 of 3 runs). The commit drops
`grpcroutes.gateway.networking.k8s.io` from the bundle, with `prune: true` and no
`Prune=false`:

```text
live Gateway API CRDs: 10
pushed 2d5c2fc8…: gateway CRDs: drop grpcroutes.gateway.networking.k8s.io
gateway-api-crds: Synced at 2d5c2fc8, last operation Succeeded
crd/grpcroutes.gateway.networking.k8s.io: still in the cluster (not pruned)
  in the Application: no
```

The Application stays `Synced`, ran no operation for that commit, and no longer lists
the CRD among its resources. Nothing in Argo CD shows that the CRD is left over.

## TCPRoute and UDPRoute are in the standard channel

The pinned v1.6.2 `standard-install.yaml` ships `tcproutes`, `udproutes` and
`listenersets` with `channel: standard` ([re-run
review](https://github.com/gsuquet/infra/pull/13#issuecomment-7003896433), not checked
again here).
[ADR-0012](https://github.com/gsuquet/infra/blob/main/docs/adr/0012-gateway-api-crd-ownership.md)
lists TCPRoute and UDPRoute as experimental and deferred.
