---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Store kind state locally and other cluster states in the R2 backend

## Context and Problem Statement

Each cluster root (`clusters/<name>/`) has Terraform state. kind clusters are disposable and per machine; Talos
and GKE clusters are long-lived. Where does each state live?

## Decision Drivers

* Long-lived state must survive a lost laptop and support locking.
* Disposable clusters must not need credentials.
* Reuse the existing R2 bucket from the Cloudflare landing zone.

## Considered Options

* kind: local state; others: R2 (`terraform-state`, key `clusters/<name>/terraform.tfstate`)
* R2 for every cluster, including kind
* GCS for GKE, R2 for Talos

## Decision Outcome

Chosen option: "kind local, others R2". Non-kind roots use the S3 backend against the existing R2 bucket
`terraform-state`, key `clusters/<name>/terraform.tfstate`, with `use_lockfile = true` and the same R2
compatibility flags as `landing-zone/cloudflare/backend.tf`.

### Consequences

* Good, because `cluster:up` on kind works offline and without secrets.
* Good, because one backend for all long-lived state.
* Bad, because R2 has no object versioning: a corrupted state cannot be restored from the bucket.
* Bad, because GKE state lives on Cloudflare, outside Google Cloud.
* Bad, because kind state is lost with the machine; acceptable for a disposable cluster.

### Confirmation

Every `clusters/<name>/backend.tf` of a non-kind cluster uses key `clusters/<name>/terraform.tfstate`; kind
roots declare no remote backend.

## Pros and Cons of the Options

### kind local, others R2

* Good, because matches each cluster's lifetime.
* Bad, because two backend styles.

### R2 everywhere

* Good, because uniform.
* Bad, because a dev cluster needs Cloudflare credentials.

### GCS for GKE

* Good, because versioning and locality.
* Bad, because a second backend and a bootstrap bucket.
