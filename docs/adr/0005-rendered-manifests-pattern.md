---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Commit rendered manifests and apply them with sync waves

## Context and Problem Statement

Most components ship as Helm charts. Argo CD can render charts at sync time, or apply plain YAML that a task
rendered and committed. How do Helm sources reach the cluster?

## Decision Drivers

* A pull request must show the exact resources that change, per cluster.
* Static checks (kubeconform, Conftest) must read the real output, not templates.
* A sync, including Argo CD repairing itself, must not depend on a chart repository being reachable.
* Ordering: CRDs before the resources that use them.

## Considered Options

* Rendered manifests committed to Git, applied as plain YAML
* Argo CD renders Helm charts at sync time
* Argo CD Config Management Plugin that renders at sync time

## Decision Outcome

Chosen option: "Rendered manifests committed to Git, applied as plain YAML", everywhere: cluster components here
and tenant manifests in `gsuquet/gitops` (ADR-0007).

* `mise run manifests:render` renders each enabled component of each cluster into
  `gitops/clusters/<name>/rendered/<component>/`, one file per resource.
* Argo CD applies those files as a directory source, with no Helm.
* Sync waves order the apply: `CustomResourceDefinition` resources get wave `-1`, ordinary resources stay on the
  default wave `0`, and child `Application` resources get wave `1` or higher.

### Consequences

* Good, because reviewers see every changed field of every cluster.
* Good, because the bootstrap module applies the same `rendered/argocd/` files that Argo CD later adopts.
* Good, because Conftest and kubeconform check exactly what reaches the cluster.
* Bad, because upgrades produce large diffs.
* Bad, because a source change without a render leaves stale files; `mise run manifests:check` in CI fails on
  any difference (ADR-0019), so Renovate chart bumps need a render commit.
* Bad, because Helm hooks are not run by Argo CD as Helm hooks; charts that rely on hooks need review at render
  time.

### Confirmation

CI runs `mise run manifests:check`; no Argo CD `Application` in `rendered/` has a `helm` source.

## Pros and Cons of the Options

### Rendered manifests committed to Git

* Good, because Git is the full desired state.
* Bad, because the repository grows with rendered YAML.

### Argo CD renders Helm charts at sync time

* Good, because small diffs and no render step.
* Bad, because the applied resources are invisible in review and to static checks.

### Config Management Plugin

* Good, because flexible rendering.
* Bad, because custom sidecars in Argo CD, and the output is still not in Git.

## More Information

* [Argo CD sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
* `homelab` explanation page "Rendered manifests pattern" (reference implementation)
