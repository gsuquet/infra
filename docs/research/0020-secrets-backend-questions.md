# Secrets backend questions

The alternatives behind the open questions of [RFC 0020](../rfc/0020-secrets-backend.md#open-questions). None is answered here.

<!-- readability: allow-code R2 -->

## GCP projects

One GCP project for the secrets of all clusters, or one per environment (prod / non-prod)? This also decides whether GKE clusters share a workload identity pool, and so share principals.

## Secret naming

Which names, which also set the IAM `<name-prefix>`: shared tenant-prefixed (`<tenant>--<namespace>--<name>`, platform namespaces `platform--<namespace>--<name>`), shared without tenant (`<namespace>--<name>`), per cluster (`<cluster>--<namespace>--<name>`), or a mix? Per-cluster names cost one write per cluster.

## Write path

IaC write-only (`secret_data_wo`, a version counter in Git, a person-only root) or a `gcloud secrets versions add --data-file=-` pipe from `pass-cli` (no state)?

## Writer identity

A separate Google account, or impersonation of a writer service account that the daily gcloud configuration cannot use without an explicit step?

## remoteRef convention

Plain payloads with no `property` (works with `fake` and, if the test confirms it, `gcpsm`), or JSON payloads with `property: value` (keeps homelab objects)?

## Tenant scope

May a tenant `ExternalSecret` read only secrets prefixed with its tenant name, enforced by prefix-conditioned IAM on its namespace principals? Who writes tenant values? Does the tenant file in `infra` list secret keys (feeding kind dummies and IAM)?

## Talos state isolation

A separate R2 credential agents do not hold, person-only `cluster:up`/`plan` for production Talos roots, or a signing key generated outside IaC?

## Proton Pass session

A dedicated vault for cluster values, a separate login, re-authentication per use, a session lifetime?

## Bootstrap boundary

Talos workload identity provider and JWKS in `landing-zone/gcp`, fed by a committed public JWKS (proposed), or in the cluster root (which then needs Google credentials and a post-bootstrap API read in every `cluster:up`)?
