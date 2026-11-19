---
adr: 0016
title: Read secrets through an ESO store named secrets
status: accepted
date: 2026-11-18
rfc: docs/rfc/0016-secret-store-named-secrets.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0016. Read secrets through an ESO store named secrets

- Status: accepted on 2026-11-18 by gsuquet
- Decision: In the context of platform components and tenants that need secrets before the backend is chosen, facing public repositories and kind clusters with no credentials, we decided for the External Secrets Operator with a namespaced `SecretStore` named `secrets` in every namespace, rendered by the platform (tenant namespaces through onboarding), never a `ClusterSecretStore`, with every `ExternalSecret` setting `secretStoreRef: {kind: SecretStore, name: secrets}` and kind using an in-cluster backend with dummy values, and against backend-specific store names and SOPS-encrypted secrets in Git, to achieve consumers that never change when the backend changes, accepting one indirection and one backend credential or identity binding per namespace.
- Consequences:
  - Good: changing the backend changes only the rendered stores, not consumers.
  - Good: kind runs the full catalog with no credentials.
  - Bad: all consumers get the same interface, even where a backend offers richer features.
  - Bad: one store per namespace means one backend credential or identity binding per namespace, rendered by the platform.
  - Bad: a tenant could ship its own `SecretStore` named `secrets` and fight the platform one until `SecretStore` is in the tenant blacklist (pending the owner's decision).
- Confidence: high, the store name is backend-agnostic by construction.
- Confirmation: a Conftest policy fails any `ExternalSecret` whose `secretStoreRef` is not `kind: SecretStore`, `name: secrets`, any `ClusterSecretStore`, and any `Secret` with `data` or `stringData` in rendered manifests.
- Revisit when: the backend chosen in RFC 0020 cannot serve a namespaced store per namespace.

Source: [RFC 0016](../../docs/rfc/0016-secret-store-named-secrets.md), reviewed in https://github.com/gsuquet/infra/pull/5.
