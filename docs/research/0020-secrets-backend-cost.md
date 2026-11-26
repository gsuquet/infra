# Secrets backend cost

Cost evidence for [RFC 0020](../rfc/0020-secrets-backend.md). Basis of its estimate: 40 secrets with one enabled version each (older destroyed), 3 non-kind clusters, every value read by every cluster, single-location replication, `refreshInterval: 1h`.

Cost basis, from the [pricing page](https://cloud.google.com/secret-manager/pricing) read on 2026-11-18 **(unverified)**: the page renders by JavaScript and a plain fetch returns only its title. Check in a browser.

| Item | Free per month, per account | Above the free tier | Estimate |
| --- | --- | --- | --- |
| Active secret versions | 6 | USD 0.06 per version per month | (40 - 6) x 0.06 = USD 2.04 |
| Access operations | 10,000 | USD 0.03 per 10,000 | 40 x 3 x 24 x 30 = 86,400, about USD 0.23 |
| Destroyed versions, management operations | all | free | 0 |
| Rotation notifications | 3 | USD 0.05 each | 0 |

**(unverified)**: one access per refresh per `ExternalSecret`; whether a version replicated to several locations counts once or per location (automatic or multi-location replication would multiply the version cost); whether "account" means billing account; disabled (not destroyed) versions likely still count as active, so destroy old versions after a rotation. A 24h refresh removes almost all the access cost.
