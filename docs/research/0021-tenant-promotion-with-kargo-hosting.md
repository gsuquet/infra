# Kargo hosting and kind sandbox

Detail of [RFC 0021](../rfc/0021-tenant-promotion-with-kargo.md). Study date 2026-11-18, against Kargo source tag `v1.12.6`.
"Verified" means checked against the linked source; "unverified" means prior knowledge, inference, or
unreachable source. The source links are in [sources](0021-tenant-promotion-with-kargo-evidence.md#sources).

## Hosting

| Phase | Host | Consequence |
| --- | --- | --- |
| Slice 1 | One named kind cluster; Kargo promotes to an in-cluster Gitea copy of the `gsuquet/gitops` layout, dummy credentials from the `fake` store | Builds and tests the flow offline; nothing reaches `gsuquet/gitops`; GitHub App auth is not exercised |
| Slice 2 | First long-lived cluster (Talos on Pis or GKE, open question [Kargo host](../rfc/0021-tenant-promotion-with-kargo.md#open-questions)), enabled in its own `cluster.yaml` | Real GitHub App credential; the only Kargo that writes to `gsuquet/gitops`. Pi costs nothing extra; GKE adds compute cost and the FQDN policy risk |

Why kind cannot write to `gsuquet/gitops`:

| Conflict | Detail |
| --- | --- |
| No real credential | The `fake` store gives a dummy App key: `git-push`, `git-open-pr`, `git-wait-for-pr` fail, and `git-clone` too while a dummy credential matches the public URL (unverified) |
| Several kind clusters | kind runs on several machines; enabled in shared kind settings, each would open the same pull requests |
| Promotion order | Stage `pi` takes Freight with `sources.stages: [kind]`. A recreated kind host has no Freight promoted to `kind`, so nothing is eligible for `pi` until `kind` is promoted again, even when Git already holds it. Every `cluster:down` loses the order |

| kind option | Trade-off |
| --- | --- |
| Person-seeded real App key on one named kind cluster, `kargo` only in that cluster's `cluster.yaml` | Breaks ADR-0016 "kind runs with no credentials" and the Conftest rule "no `fake` provider outside kind" proposed by RFC 0020 (draft); needs owner sign-off; still loses promotion order at every recreate. Not proposed |
| Offline sandbox: in-cluster Gitea, kind-only opt-in component, dummy App key from the `fake` store (needs RFC 0020 to choose `fake` for kind); `git-open-pr` and `git-wait-for-pr` support `provider: gitea`, Gitea has no pull request labels yet (issue 6021) (verified), so the kind task variant drops `labels`. Gitea chart, version and footprint (unverified) | Proposed |

With the offline sandbox, `kind` is still a Stage of every tenant on the long-lived host: it writes
`tenants/<tenant>/kind/`, and every kind cluster on every machine syncs it with its own Argo CD (no
credential: the repository is public). Promotion order lives on a host that is not recreated.

- Kargo can promote the tenants of its own host: it writes Git only, so no bootstrap loop.
- A second Kargo must never watch the same Projects.
- UI and API: an internal `HTTPRoute` on the cluster gateway, or `cloudflared` behind Cloudflare
  Access. External webhooks stay off: Warehouse polling and the pull request poll suffice.
