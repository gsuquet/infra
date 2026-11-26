---
adr: 0008
title: Promote tenant releases with Kargo git-only steps
status: accepted
date: 2026-11-18
rfc: docs/rfc/0008-kargo-git-only-promotion.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0008. Promote tenant releases with Kargo git-only steps

- Status: accepted on 2026-11-18 by gsuquet
- Context: promoting tenant releases through stages (for example kind, then Talos, then GKE), facing Kargo's choice between Git writes and driving Argo CD.
- Decision: we decided for Kargo with git-only promotion steps (render the tenant manifests for the target stage, open a pull request to `gsuquet/gitops` under `tenants/<tenant>/<cluster>/`, Argo CD syncs after the merge; Kargo is an opt-in component), and against the `argocd-update` step and manual pull requests, to achieve Git as the only source of desired state with every promotion reviewable, accepting promotion latency of a merge plus a sync interval.
- Consequences:
  - Good: each promotion is a commit with a diff.
  - Good: Kargo needs no write access to any Argo CD.
  - Bad: promotion latency includes the pull request merge and the Argo CD sync interval.
  - Bad: Kargo health verification cannot rely on the `argocd-update` step's feedback.
  - Bad: the exact git step names are unverified until checked against the Kargo documentation at implementation.
  - Bad: deferred: where Kargo itself runs and the stage layout (RFC 0021).
- Confidence: medium, the git step names and the stage layout are not verified yet.
- Confirmation: no Kargo `Stage` in `infra` or `gsuquet/gitops` uses an `argocd-update` step.
- Revisit when: promotion latency blocks releases, or RFC 0021 (Kargo tenant promotion) is accepted.

Source: [RFC 0008](../../docs/rfc/0008-kargo-git-only-promotion.md), reviewed in https://github.com/gsuquet/infra/pull/5.
