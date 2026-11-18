---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Read secrets through an External Secrets store named secrets in every namespace

## Context and Problem Statement

The secrets backend (cloud secret manager, password manager, in-cluster vault, ...) is still under study
(reserved ADR-0020). Platform components and tenants need a stable way to request secrets now, without
binding to a backend.

## Decision Drivers

* Manifests must not change when the backend changes.
* Public repositories: no secret value in Git, ever.
* kind clusters must work without any real credential.

## Considered Options

* External Secrets Operator with a store named `secrets` in every namespace
* Backend-specific store names in each manifest
* SOPS-encrypted secrets in Git

## Decision Outcome

Chosen option: "External Secrets Operator with a store named `secrets` in every namespace". Every
`ExternalSecret` references the store `secrets`. The platform renders that store for each namespace (tenant
namespaces through onboarding, ADR-0009). On kind, the store is an in-cluster backend with dummy values.

### Consequences

* Good, because changing the backend changes only the rendered stores, not consumers.
* Good, because kind runs the full catalog with no credentials.
* Bad, because all consumers get the same interface, even where a backend offers richer features.
* Open: the backend itself (ADR-0020), the store kind (`SecretStore` per namespace or a `ClusterSecretStore` with
  namespace conditions), and the kind in-cluster provider (ESO `fake` or `kubernetes` provider).

### Confirmation

A Conftest policy fails any `ExternalSecret` whose `secretStoreRef.name` is not `secrets`, and any `Secret` with
`data` or `stringData` in rendered manifests.

## Pros and Cons of the Options

### ESO store named `secrets`

* Good, because backend-agnostic.
* Bad, because one more indirection.

### Backend-specific store names

* Good, because explicit.
* Bad, because a backend change edits every consumer.

### SOPS in Git

* Good, because no runtime dependency.
* Bad, because encrypted secrets in public repositories and key management per cluster.

## More Information

* [External Secrets Operator](https://external-secrets.io/)
