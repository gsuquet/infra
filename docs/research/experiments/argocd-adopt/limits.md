# Failures and limits of the argocd-adopt experiment

Back to the [experiment summary](../argocd-adopt.md).

## What failed

- **First run: the bootstrap split.** `cat rendered/argocd/*.yaml` glued the last
  document of `manifest.yaml` to the first one of `namespace.yaml` (no `---` between
  files), so the Namespace was lost and the apply failed with `namespaces "argocd" not
  found`. Fix: each file is its own document stream. The Terraform module must split per
  file and per document (the homelab module does: `fileset` then `split("\n---\n", …)`).
  The cleanup trap deleted the cluster as intended.
- **Investigations, not failures:** runs 2 to 5 added diagnostics for the Deployment
  generation bump, the CRD tracking and the hook Jobs. The results did not change
  between runs.
- **Re-run, script bugs (fixed in `run.sh`):**
  - **The OutOfSync recording missed the OutOfSync state.** The first attempt of the
    defaults run synced the `argocd` Application on the probe commit again, but the list
    of OutOfSync resources was empty: the 5 s poll inside `wait_apps` never saw the
    state, which lasted about 2 s. Fix: a `kubectl get applications -w -o json` watch
    from the hand-over on, parsed per revision. The three kept runs all used the watch.
    All other results of that first attempt matched the defaults run.
  - **"What the first syncs did" showed the last operation.** `.status.operationState`
    holds only the last operation; for the `argocd` Application at the hand-over that is
    the partial self-heal sync (one Application, no hook). Fix: the label says "last
    sync", and the result phase lists every operation from the watch
    (`show_operations`).
  - **The controller log filter matched nothing**: it grepped for `argocd/argocd`, but
    the log has `application=argocd`. Fixed.
  - The last two fixes only change how `run.sh` prints saved data. They were made after
    the three runs and checked against the saved `apps-watch.json` and
    `controller-phase5.log` of each run (the offline excerpts come from them). The
    cluster steps did not change.

## Which script ran

An uncommitted `run.sh` made the three kept runs; the committed one never ran as it is
([re-run review](https://github.com/gsuquet/infra/pull/13#issuecomment-7003896433)).

| Change in `run.sh` | When |
|---|---|
| The watch of the Applications (`start_apps_watch`) and its parsing per revision | before the kept runs, new in `6098d5c` since `857fbe5` |
| The controller-log block, with the save to `controller-phase5.log` | before the kept runs, new in `6098d5c` since `857fbe5` |
| The controller-log filter (`application=argocd`) | after the kept runs |
| The "last sync" labels and `show_operations` | after the kept runs |

## Not tested

A real Terraform run (the `kubectl` provider), client-side apply or client-side diff as
controls, a Cilium chart upgrade through Argo CD, an upgrade of the Gateway API bundle
to a new version (only a label change and a removed CRD), multi-replica Argo CD, Argo CD
HA Redis, the downtime of the data plane during a Cilium upgrade, a GitHub webhook, a
fix for the self-sync race.
