---
adr: 0001
title: Record decisions as RFCs with generated ADRs
status: accepted
date: 2026-11-19
rfc: docs/rfc/0001-record-decisions-with-madr.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0001. Record decisions as RFCs with generated ADRs

- Status: accepted on 2026-11-19 by gsuquet
- Decision: In the context of recording the structural decisions of `infra`, facing hand-written MADR prose that mixes debate and outcome and has no review state, we decided for one RFC per decision in `docs/rfc/NNNN-slug.md` (lifecycle draft, review, accepted, rejected, withdrawn, superseded; reviewed in a pull request) whose accepted Decision section is copied verbatim into a generated ADR `docs/adr/NNNN-slug.md` with the same number, and against hand-written MADR, explanation pages and decisions kept only in pull request descriptions, to achieve a reviewed human record and a compact ADR that agents read, accepting two files per decision and a heavier template.
- Consequences:
  - Good: an ADR holds only the Decision block, the cheapest form for agents to read.
  - Good: each decision has a stable link, a status and its review pull request in front matter.
  - Good: numbers are pre-assigned (0020 secrets backend, 0021 Kargo tenant promotion, 0022 IaC tool, 0023 Renovate with rendered manifests, 0024 GKE, 0025 Talos on Raspberry Pi, 0026 Cloudflare Tunnel), so parallel branches do not collide.
  - Bad: an ADR is never edited by hand; an accepted RFC changes only through Implementation links or a new RFC that supersedes it.
  - Bad: READMEs and ADRs can drift: READMEs describe the current state and link the ADR for the why.
- Confidence: high, every MADR record moves into its retro RFC with no loss of substance.
- Confirmation: the RFC check passes on every file of `docs/rfc/` and fails when an ADR differs from its RFC's Decision section; every structural pull request links an RFC or adds one; `docs/rfc/README.md` and `docs/adr/README.md` list every file.
- Revisit when: a structural change merges without an RFC, or the RFC process costs more review time than the changes it records.

Source: [RFC 0001](../../docs/rfc/0001-record-decisions-with-madr.md), reviewed in https://github.com/gsuquet/infra/pull/5.
