# Kargo components, install and network policy

Detail of [RFC 0021](../rfc/0021-tenant-promotion-with-kargo.md). Study date 2026-11-18, against Kargo source tag `v1.12.6`.
"Verified" means checked against the linked source; "unverified" means prior knowledge, inference, or
unreachable source. The source links are in [sources](0021-tenant-promotion-with-kargo-evidence.md#sources).

## Architecture

| Component | Required | Internet-facing | Role (verified, architecture page) |
| --- | --- | --- | --- |
| API server | yes | yes (UI, CLI) | Backend for UI and CLI, serves the UI |
| Controller | yes | no | Watches Warehouses, runs Promotions and health checks, creates `AnalysisRun`s |
| Management controller | yes | no | Per-Project RBAC; broad permissions, never distributed |
| Kubernetes webhooks server | yes | no | Admission webhooks; TLS from a cert-manager self-signed `Issuer` by default |
| External webhooks server | no: disabled | yes | Push notifications to refresh Warehouses; polling is enough here |
| Garbage collector | default on | no | Hourly CronJob deleting old Promotions and unused Freight |
| Dex | no | via API server | OIDC adapter, for example GitHub (open question [UI access](../rfc/0021-tenant-promotion-with-kargo.md#open-questions)) |

All state is custom resources on the host cluster; no database (verified). Standalone topology is
documented for testing and "very small deployments" (verified). Sharding exists to reach several Argo
CD instances (a shard "typically corresponds to one Argo CD control plane"; chart values
`kubeconfigSecrets.kargo` and `kubeconfigSecrets.argocd`) (verified), so git-only needs no shard.

| Kind (chart `v1.12.6`, verified) | Scope | Use here |
| --- | --- | --- |
| `Project` | cluster | One per tenant; creates or adopts a namespace of the same name (tenancy and RBAC boundary) |
| `ProjectConfig` | one per Project | Auto-promotion per Stage selector, promotion windows, webhook receivers, auto-rollback |
| `Warehouse` | namespaced | Subscribes to the tenant image and OCI chart (optionally a Git path); emits Freight |
| `Freight` | namespaced | Immutable set of revisions (image tag or digest, chart version, commit) |
| `Stage` | namespaced | One per tenant and cluster: `requestedFreight`, `promotionTemplate`, optional `verification` |
| `Promotion` | namespaced | One run of a Stage's steps for one Freight, inside the controller process |
| `PromotionTask` / `ClusterPromotionTask` | namespaced / cluster | Reusable steps; the platform owns one `ClusterPromotionTask` |
| `ClusterConfig` | cluster | Default Git committer identity, webhook receivers |
| `PromotionRequest`, `Target` | namespaced | In `v1.12` source, absent from its docs (verified): unreleased, do not design on them |

`AnalysisTemplate` and `AnalysisRun` are Argo Rollouts kinds; Kargo ships only Go stubs (verified).
Promotions to one Stage run one at a time (`status.currentPromotion`), and none run while a
verification runs (verified).

## Network policy

The cluster default deny (ADR-0010, now hosted by the `network-policy` component) applies to the
`kargo` namespace.

| Flow | Peer |
| --- | --- |
| Egress: controller, management controller, API server, `garbage-collector` pods | Kubernetes API (`kube-apiserver` entity; already a baseline allow, listed so `kargo` does not depend on it silently) |
| Egress: controller, and API server reading Freight sources for the UI (unverified) | `github.com`, `api.github.com`, `ghcr.io`, `pkg-containers.githubusercontent.com` on TCP 443 (`ghcr.io` redirects blobs there: unverified, observed behaviour) |
| Egress: `kargo` namespace to kube-dns | DNS rule (`rules.dns`) so Cilium learns FQDNs (verified, Cilium `stable` docs); that `toFQDNs` fails without it is unverified; Cilium version not pinned here |
| Ingress: webhooks server | Kubernetes API server (`kube-apiserver` or `remote-node` entity, per distribution) |
| Ingress: `api` Service | Gateway namespace (internal `HTTPRoute`) or `cloudflared` namespace |
| Egress: verification Jobs, if adopted | The URLs they probe |
| Egress on kind, [offline sandbox](0021-tenant-promotion-with-kargo-hosting.md#hosting) | In-cluster Gitea Service instead of GitHub |

GKE Dataplane V2 is a managed Cilium: support for `CiliumClusterwideNetworkPolicy` and FQDN rules
is an unverified risk with a plain `NetworkPolicy` fallback that cannot express FQDN egress. A GKE
Kargo host depends on resolving it first (GKE's own FQDN network policy feature: unverified).

## Install

| Item | Value |
| --- | --- |
| Version | Kargo `v1.12.6`, chart `oci://ghcr.io/akuity/kargo-charts/kargo` `1.12.6` (published artifact not pulled: unverified), API `kargo.akuity.io/v1alpha1`, Apache-2.0 |
| Component | Opt-in catalog component `kargo`; placement rule: [Confirmation checks](0021-tenant-promotion-with-kargo-tenancy.md#confirmation-checks) |
| Integrations | `controller.argocd.integrationEnabled: false` (fewer controller permissions, as the docs recommend), `api.rollouts.integrationEnabled: false`, `controller.rollouts.integrationEnabled: false` |
| Deployments | `api`, `controller`, `management-controller`, `webhooks-server`; `external-webhooks-server` disabled; `dex-server` only with Dex; CronJob `garbage-collector`; replicas `1` |
| Namespaces | `kargo-system-resources`, `kargo-shared-resources`: `createNamespace: false`, rendered with the policy label |
| TLS | cert-manager self-signed certificates (`*.tls.selfSignedCert`); cert-manager is baseline |
| Resources | Chart sets `resources: {}` everywhere: the platform sets requests and limits after measuring |
| Images | `linux/amd64` and `linux/arm64`: runs on a Pi 4 |
| CRDs | Templated in the chart (`templates/crds.yaml`), rendered by `helm template`, sync wave `-1` |

Footprint is unmeasured: no sizing data in the docs, and `ghcr.io` images were outside the study's
fetch scope. Estimate (unverified): five small Go processes at a few tens of MiB each when idle, about
0.5 GiB of memory requests in total, plus about 0.2 GiB for an Argo
Rollouts controller if adopted, next to Talos, Cilium, Argo CD, cert-manager and ESO on a Pi 4 with
8 GiB; the controller spikes during Promotions (`git clone`, `helm template` in-process). Gate: in
slice 1, record `kubectl top pod` (metrics-server on kind) for every Kargo pod, idle and during a
realistic Promotion, and record the peaks in the `kargo` component README
(`gitops/components/kargo/README.md`, linked from Implementation) before fixing requests and limits
and accepting a Pi as host. This RFC stays unchanged once accepted.
