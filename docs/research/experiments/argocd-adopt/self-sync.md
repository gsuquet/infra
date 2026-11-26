# Self-sync of the argocd Application

Back to the [experiment summary](../argocd-adopt.md).

Sync `#1` in the [sync history](self-upgrade.md#chart-version) is for the probe and CRD
commit, which does not change `rendered/argocd/`. Argo CD auto-syncs only an OutOfSync
Application ([auto-sync
docs](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/#automated-sync-semantics);
`autoSync` returns early on any other status,
[`controller/appcontroller.go#L2439`](https://github.com/argoproj/argo-cd/blob/v3.5.6/controller/appcontroller.go#L2439)).
Each such sync is a full sync: 46 resources and the `argocd-redis-secret-init` PreSync
Job again.

| Configuration | Self-sync on the probe and CRD commit? | `argocd` resources OutOfSync at that commit |
| --- | --- | --- |
| defaults (first attempt) | yes (history #1 at `8ee74029`) | not recorded ([script bug](limits.md#what-failed)) |
| defaults | yes (history #1 at `e77496e7`) | `Application/argocd/gateway-api-crds` |
| `REFRESH_SELF=false` | no | none |
| `GENERATE_PATHS=true` | no | none |

## What the watch shows

In the defaults run, the `argocd` Application compared the new revision at 07:51:52
while the child `gateway-api-crds` was running its own sync of that commit (the CRD
label change). It saw that child Application OutOfSync, and auto-synced 2 s later. The
"controller log" lines were extracted after the run from the saved log; the live run
printed nothing there ([filter bug](limits.md#what-failed)):

```text
argocd Application resources seen OutOfSync at e77496e7 (watch):
  Application/argocd/gateway-api-crds
(end of list)
argocd Application updates at e77496e7 (sync status, operation phase):
    1 OutOfSync -
    1 OutOfSync Running
    8 Synced Running
    2 Synced Succeeded
controller log:
  2026-11-19T07:51:52Z Refreshing app status (normal refresh requested), level (3)
  2026-11-19T07:51:54Z Initiated automated sync to 'e77496e7…'
```

The same pattern shows in all three runs at the hand-over: whenever the `argocd`
Application listed a child Application as OutOfSync, the watch had that child with an
`operation` in flight (the child's live object carries `.operation`, set by the
controller while it syncs). That explains the partial self-heal sync at the hand-over,
too.

## Why the other runs did not sync

Times are UTC. The trigger is a child Application, not the self-refresh of the `argocd`
Application that `run.sh` requests. Child Application writes are **supported** as the
cause, **but as a race**: the `argocd` Application syncs itself only if it compares
while a child sync is in flight.

- `REFRESH_SELF=false`: the `argocd` Application got no refresh on the push and compared
  the commit only at its periodic reconcile ("comparison expired", 08:01:58), 29 s after
  the children had finished their syncs (08:01:29). No overlap, no sync. This says
  nothing about the self-reference.
- `GENERATE_PATHS=true`: the `argocd` Application compared the commit at 08:16:55
  (normal refresh, level 3) and stayed Synced, although the watch had `gateway-api-crds`
  with an operation in flight at that moment. One run, and the timing of the watch is
  not precise enough to say whether the comparison saw the child before or after the
  operation was set. `manifest-generate-paths` only skips manifest generation; the diff
  against the live child still runs
  ([`controller/state.go#L457`](https://github.com/argoproj/argo-cd/blob/v3.5.6/controller/state.go#L457)),
  so with the refresh annotation that `run.sh` sets, it does not prevent this diff. With
  a GitHub webhook it can: the webhook handler skips the refresh of an Application whose
  paths do not match the changed files (`util/webhook/webhook.go`), so the parent would
  not compare at the same time as its children. Source: the [re-run
  review](https://github.com/gsuquet/infra/pull/13#issuecomment-7003896433); not tested
  with a webhook, and the v3.5.6 source was not read again. **Not proven as a fix.** The
  same review reads the child as having `.operation` set while the parent compared
  (08:16:55 to 08:16:57, child operation started 08:16:56): weak evidence against the
  `.operation` hypothesis.

## Unproven

Not proven: which field of the child makes the diff (most likely `.operation`, which the
Git manifest does not have; the diff itself was not captured), and how often it hits. In
production, a GitHub webhook refreshes every Application of the repository at once,
which is the overlap the defaults run creates, unless `manifest-generate-paths` skips
that refresh (see [the other runs](#why-the-other-runs-did-not-sync); not tested). With
polling only, the overlap depends on the jitter.
