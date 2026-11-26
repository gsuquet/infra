# Self-upgrade results

Back to the [experiment summary](../argocd-adopt.md).

## Value bump

Commit: `controller.status.processors` 20 → 10. It changes `argocd-cmd-params-cm` and
the `checksum/cmd-params` annotation of four pod templates, so the application
controller restarts during its own sync.

```text
all 4 Applications Synced and Healthy at 1fbf67c5 after 30s
argocd Application resources seen OutOfSync at 1fbf67c5 (watch):
  ConfigMap/argocd/argocd-cmd-params-cm
  Deployment/argocd/argocd-applicationset-controller
  Deployment/argocd/argocd-repo-server
  Deployment/argocd/argocd-server
  StatefulSet/argocd/argocd-application-controller
(end of list)
argocd-server /healthz: 39 ok, 0 failed probes (1 per second)
argocd-cmd-params-cm controller.status.processors: 10
```

`/healthz` failures in the three re-run configurations: 0 of 39, 0 of 165
(`REFRESH_SELF=false`, which waits for the periodic reconcile), 0 of 40.

New pods for the application controller, the ApplicationSet controller, the repo server
and the server; Redis (no checksum annotation) kept its pod. All restart counts 0. The
`/healthz` probe goes through the API server service proxy, so a pod replacement does
not break the probe itself.

## Chart version

Commit: argo-cd chart 10.11.6 → 10.11.7 (Argo CD v3.5.6 → v3.5.7, 100 lines changed in
the rendered file).

```text
all 4 Applications Synced and Healthy at e02f8067 after 61s
argocd-server /healthz: 69 ok, 0 failed probes (1 per second)
Argo CD images now running:
  ecr-public.aws.com/docker/library/redis:8.6.4-alpine
  quay.io/argoproj/argocd:v3.5.7
argocd app last operation: Succeeded - successfully synced (all tasks run)
```

`/healthz` failures in the three re-run configurations: 0 of 69, 0 of 260, 0 of 64. The
sync history of the `argocd` Application (defaults run):

```text
#0 rev e3ded2a2 started 2026-11-19T07:46:31Z deployed 2026-11-19T07:46:44Z by auto-sync
#1 rev e77496e7 started 2026-11-19T07:51:54Z deployed 2026-11-19T07:52:06Z by auto-sync
#2 rev 1fbf67c5 started 2026-11-19T07:52:37Z deployed 2026-11-19T07:53:01Z by auto-sync
#3 rev e02f8067 started 2026-11-19T07:53:19Z deployed 2026-11-19T07:53:58Z by auto-sync
```
