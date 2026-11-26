---
adr: 0002
title: Build infra as a greenfield successor of homelab
status: accepted
date: 2026-11-18
rfc: docs/rfc/0002-greenfield-successor-of-homelab.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0002. Build infra as a greenfield successor of homelab

- Status: accepted on 2026-11-18 by gsuquet
- Context: delivering the new platform design (Talos, rendered manifests, tenants, Gateway API), facing a legacy repository coupled to the production k3s cluster `olympus`.
- Decision: we decided for a greenfield `gsuquet/infra` with `gsuquet/homelab` frozen (no new features; it runs `olympus` until a Talos Raspberry Pi cluster from `infra` replaces it, then it is archived; its `modules/`, `gitops/`, `policy/`, `schemas/`, `docs/` and `.mise` tasks are a reference, rewritten and never copied blindly), and against continuing the in-place migration in `homelab`, to achieve a clean tree with no Ansible that cannot break production, accepting two repositories during the transition.
- Consequences:
  - Good: `infra` starts clean, with no Ansible and no legacy folder.
  - Good: the production cluster is not touched by design experiments.
  - Bad: fixes to `olympus` still happen in `homelab` until the cut-over.
  - Bad: the history of reused ideas stays in `homelab`; the decisions are recorded again here.
  - Bad: shared logic (render, policies) is rewritten.
- Confidence: high, the coupling to the running cluster was the main cost of every change in `homelab`.
- Confirmation: `homelab` receives no feature pull request after 2026-11-18; `infra` contains no `ansible/` folder.
- Revisit when: the Talos Raspberry Pi cluster is ready to replace `olympus` (the cut-over RFC).

Source: [RFC 0002](../../docs/rfc/0002-greenfield-successor-of-homelab.md), reviewed in https://github.com/gsuquet/infra/pull/5.
