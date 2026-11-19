---
adr: 0018
title: Keep kind state local and other cluster states in R2
status: accepted
date: 2026-11-18
rfc: docs/rfc/0018-terraform-state-backends.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0018. Keep kind state local and other cluster states in R2

- Status: accepted on 2026-11-18 by gsuquet
- Decision: In the context of state for cluster roots with very different lifetimes, facing disposable kind clusters and long-lived Talos and GKE clusters, we decided for local state on kind roots (no remote backend) and, on every other root, the S3 backend against the existing R2 bucket `terraform-state` with key `clusters/<name>/terraform.tfstate`, `use_lockfile = true` and the R2 compatibility flags of `landing-zone/cloudflare/backend.tf`, and against R2 for every cluster and GCS for GKE, to achieve offline credential-free kind clusters and one locked backend for all long-lived state, accepting no object versioning on R2.
- Consequences:
  - Good: `cluster:up` on kind works offline and without secrets.
  - Good: one backend for all long-lived state.
  - Bad: R2 has no object versioning: a corrupted state cannot be restored from the bucket.
  - Bad: GKE state lives on Cloudflare, outside Google Cloud.
  - Bad: kind state is lost with the machine; acceptable for a disposable cluster.
- Confidence: high, the landing zone already runs on the same backend.
- Confirmation: every `clusters/<name>/backend.tf` of a non-kind cluster uses key `clusters/<name>/terraform.tfstate`; kind roots declare no remote backend.
- Revisit when: a state is lost or corrupted in R2, or R2 gains object versioning.

Source: [RFC 0018](../../docs/rfc/0018-terraform-state-backends.md), reviewed in https://github.com/gsuquet/infra/pull/5.
