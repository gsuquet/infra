# Adoption results

Back to the [experiment summary](../argocd-adopt.md).

Excerpts are from the re-run (defaults run unless marked), with the first six runs where
they agree. Every check gave the same result in the three re-run configurations, except
the [self-sync of the `argocd` Application](self-sync.md). `reconciledAt` and Kubernetes
timestamps are UTC; the "hard refresh" line and the `run.log` section headers are local
time, one hour ahead ([re-run
review](https://github.com/gsuquet/infra/pull/13#issuecomment-7003896433)).

## Render reproducibility

```text
cilium (our values): reproducible
argo-cd: reproducible
cilium with hubble.tls.auto.method=helm (chart default): NOT reproducible:
<   ca.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURF... (cut)
>   ca.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURG... (cut)
```

With the chart default, `helm template` generates a new Hubble CA and new certificates
on each render. `manifests:check` would always fail, and each render would rotate the
Hubble certificates. The experiment turns Hubble off.

## Adoption

The `argocd` Application created the three others, and all four were Synced and Healthy
20 to 21 s after the hand-over, each with one entry in its sync history (re-run: 20 s,
20 s, 21 s):

```text
all 4 Applications Synced and Healthy at e3ded2a2 after 20s
```

### Partial self-heal syncs

**The `argocd` Application runs two operations at the hand-over.** The sync history
shows one. The watch of the re-run shows a second, partial operation a second later, at
the same revision, for one child Application only. It is a `selfHeal` sync: the `argocd`
Application saw a child Application OutOfSync while that child was running its own first
sync (the same pattern as [the sync on an unrelated commit](self-sync.md)). It runs no
hook and does not add a history entry (3 of 3 runs). These lines come from the saved
watch, parsed after the run, not from the live log:

```text
2026-11-19T07:46:44Z argocd rev e3ded2a2 Succeeded: 46 resources, 4 hook resources
2026-11-19T07:46:45Z argocd rev e3ded2a2 Succeeded: 1 resources, 0 hook resources (partial sync of Application cilium)
```

(`REFRESH_SELF=false`: the same, for `cilium`; `GENERATE_PATHS=true`: the same, for
`probe`.)

The second sync is not specific to the app of apps. In the [field removal
check](field-managers.md#field-removal), the `probe` Application ran a full sync at
07:51:52 UTC and a 1-resource partial sync of `ConfigMap/probe-argocd` at 07:51:53 UTC,
at the same revision (defaults and `GENERATE_PATHS=true`). The trigger there is the
stale comparison from before the sync: the status was still OutOfSync with
`reconciledAt` 07:51:52. Source: the [re-run
review](https://github.com/gsuquet/infra/pull/13#issuecomment-7003896433), which read
the saved watch files.

### No OutOfSync loop

- **300 s watch, 3 of 3 runs.** Sampled every 5 s, with a hard refresh of all
  Applications midway: no sample not Synced, the sync history did not grow, and
  `reconciledAt` moved to the hard refresh time, so every Application ran at least one
  full comparison (level 3) in the window. The controller log also shows periodic
  reconciles ("comparison expired") of `cilium` (defaults run) and of `probe` and
  `argocd` (`GENERATE_PATHS=true`) inside the window. Limit: a flap shorter than 5 s can
  still fall between two samples; the watch file has no OutOfSync update of the `argocd`
  Application in that window either.

  ```text
  hard refresh of all Applications at 08:49:23
  reconciledAt before: [{"n":"argocd","r":"2026-11-19T07:46:45Z"},{"n":"cilium","r":"2026-11-19T07:46:45Z"},{"n":"gateway-api-crds","r":"2026-11-19T07:46:47Z"},{"n":"probe","r":"2026-11-19T07:46:44Z"}]
  reconciledAt after:  [{"n":"argocd","r":"2026-11-19T07:49:23Z"},{"n":"cilium","r":"2026-11-19T07:49:23Z"},{"n":"gateway-api-crds","r":"2026-11-19T07:49:23Z"},{"n":"probe","r":"2026-11-19T07:49:23Z"}]
  sync history before: [{"n":"argocd","h":1},{"n":"cilium","h":1},{"n":"gateway-api-crds","h":1},{"n":"probe","h":1}]
  sync history after:  [{"n":"argocd","h":1},{"n":"cilium","h":1},{"n":"gateway-api-crds","h":1},{"n":"probe","h":1}]
  samples not Synced during the watch (every 5 s): 0
  ```

### No restart

- 3 of 3 runs. Same pod UIDs and restart counts in `kube-system` and `argocd`, and the
  same pod templates:

  ```text
  pods: identical (same UIDs, same restart counts, 14 pods)
  pod templates of the Deployments: identical
  ```

### Deployment generation

- **Harmless +1** on `argocd-applicationset-controller`, `argocd-redis`,
  `argocd-repo-server`, `argocd-server` and `cilium-operator`, in the re-run too. The
  first sync adds the `argocd.argoproj.io/tracking-id` annotation. The Deployment API
  bumps `metadata.generation` on an annotation change; the DaemonSet and StatefulSet
  APIs do not. The pod template is the same, so no new ReplicaSet and no new pod. A
  control run on resources outside Argo CD shows the same:

  ```text
  control: does a metadata-only change bump the generation?
    deploy/coredns: annotation added, generation 1 -> 2
    ds/cilium: annotation added, generation 1 -> 1
  ```

### Prune and tracking

- **No prune, no delete.** No sync result has the status `Pruned`.
- **Tracking:** annotation. Argo CD added the tracking annotation on the first sync; the
  kubectl bootstrap did not set it:

  ```text
  tracking annotation on ds/cilium before adoption:
  ds/cilium: cilium:apps/DaemonSet:kube-system/cilium
  deploy/argocd-server: argocd:apps/Deployment:argocd/argocd-server
  sts/argocd-application-controller: argocd:apps/StatefulSet:argocd/argocd-application-controller
  ```

### Helm hooks

- The chart renders `argocd-redis-secret-init` (ServiceAccount, Role, RoleBinding, Job)
  with `helm.sh/hook: pre-install,pre-upgrade`. kubectl applies them as normal
  resources; Argo CD maps them to `PreSync` hooks and runs them again on each sync of
  the `argocd` Application (`before-hook-creation` replaces the bootstrap copies). No
  error, no conflict. The Job is idempotent: it creates the Redis password only if it is
  missing. Re-run: every full sync of the `argocd` Application ran the 4 hook resources;
  the partial self-heal sync at the hand-over ran none.

  ```text
  PreSync ServiceAccount/argocd-redis-secret-init: Succeeded argocd-redis-secret-init created
  PreSync Job/argocd-redis-secret-init: Succeeded Reached expected number of succeeded pods
  ```
