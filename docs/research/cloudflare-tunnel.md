# Cloudflare Tunnel exposure study

Status: proposal, input for a future ADR. Research date: 2026-11-18.

This study decides how each cluster exposes HTTP services to the internet through Cloudflare Tunnel. It covers the tunnel layout, the Terraform resources, where the connector token lives, how `cloudflared` reaches a Gateway API Gateway, TLS to the origin, Access in front of the platform UIs, and which Terraform root owns what.

Facts marked **(verified)** were checked on the date above against the source linked next to them, or against the provider schema (`terraform providers schema -json` with `cloudflare/cloudflare` 5.28.1, the version pinned in `landing-zone/cloudflare/terraform.tf`). Facts marked **(unverified)** come from prior knowledge or from a source outside the allowed documentation domains. Check them before you build on them.

## Summary

- **One remotely-managed tunnel per cluster** (`config_src = "cloudflare"`), created by the cluster's Terraform root `clusters/<name>/`. No tunnel for kind by default.
- **No `tunnel_secret` in Terraform.** Cloudflare generates the secret. Provider 5.28.1 has no write-only argument and no ephemeral resource for tunnels, and the `cloudflare_zero_trust_tunnel_cloudflared_token` data source would put the token in state. So the token never goes through Terraform: a person-run task reads it from the API and writes it into the secrets backend, and ESO delivers it from the store `secrets`.
- **The tunnel ingress is almost static**: platform hostnames that need `cloudflared` JWT validation get their own rule, and one catch-all rule sends everything else to the cluster's edge Gateway Service. Host routing happens in `HTTPRoute`s, not in the tunnel config. A tenant hostname therefore needs only a DNS record (and, when it must be public, an Access application), never a tunnel config change.
- **TLS**: Cloudflare terminates TLS at the edge. `cloudflared` talks HTTPS to the Gateway and verifies a cert-manager certificate (Let's Encrypt, DNS-01). `noTLSVerify` is not used.
- **Access**: the landing zone's catch-all Access application on `*.<domain>` already denies by default. Argo CD and Kargo UIs get their own Access application with the `owner-sensitive` policy, plus `cloudflared` JWT validation. Webhook paths get a narrower Access application.
- **Hostnames stay one level deep** (`argocd-<cluster>.gsuquet.com`, not `argocd.<cluster>.gsuquet.com`): Universal SSL on the Free plan does not cover deeper names.

## Inputs

### Current state

- `landing-zone/cloudflare/` (provider 5.28.1) manages the zones, DNSSEC, CAA, mail records, the Zero Trust organization, identity providers without a secret, Access groups, the reusable policies `<audience>-<tier>` (`owner-sensitive`, `household-standard`, `family-sensitive`) and one catch-all Access application per domain on `*.<domain>` with `household-standard`. Its README states: "Application Workers, R2 buckets and Access applications belong to the tenant layer" and "No secret value is created by a resource of this configuration".
- It outputs `zero_trust_access_policy_ids` for tenant Access applications, and `zero_trust_organization_auth_domain`.
- `gsuquet/homelab` (frozen) runs one tunnel for olympus, created in the dashboard. `kubernetes/system/cloudflare/deployment.yaml` runs one `cloudflared` replica with `tunnel --no-autoupdate run --token $(TOKEN)`, the token from a SealedSecret. Public hostnames were added in the dashboard, which created the DNS records (`docs/how-to/configure-cloudflare.md`). Nothing of it is in Terraform.

### Platform constraints

| Constraint | Consequence |
| --- | --- |
| Public repo; no secret value is created by a Terraform resource. | No `tunnel_secret`, no token data source, no Origin CA private key, no SaaS Access application client secret in any root. |
| Every namespace reads secrets through the ESO store `secrets`; the backend is open (separate study). | The connector token is one key in that backend. The design must not depend on which backend wins. |
| Rendered manifests; Argo CD applies plain YAML. | The `cloudflared` component is a catalog entry (`gitops/components/cloudflared/`), opt-in per `cluster.yaml`. No value goes through the render step. |
| Default-deny `CiliumClusterwideNetworkPolicy` on every labelled namespace. | The `cloudflared` namespace needs explicit egress to Cloudflare (port 7844) and to the Gateway, and the Gateway needs ingress from `cloudflared`. |
| Gateway API with swappable implementations; one Gateway per implementation's GatewayClass. | The tunnel targets "the edge Gateway's Service", whose name depends on the implementation. |
| kind runs offline with dummy secrets. | `cloudflared` is not enabled on kind; a dummy token would only crash-loop. |
| Terraform plan stays local; state for non-kind clusters in R2 under `clusters/<name>/terraform.tfstate`. | Tunnel, DNS and Access resources of a cluster can live in that cluster's state. |

## Facts

### Terraform resources (provider 5.28.1)

| Resource | Role | Secret in state? |
| --- | --- | --- |
| `cloudflare_zero_trust_tunnel_cloudflared` | The tunnel. `account_id`, `name`, `config_src` (`local` or `cloudflare`), `tunnel_secret` (optional, sensitive). | Only if `tunnel_secret` is set. In the schema `tunnel_secret` is `optional`, `sensitive`, **not** `computed` and **not** `write_only`, so when it is omitted the provider cannot fill it from the API response, and no other attribute holds a secret **(verified, schema)**. |
| `cloudflare_zero_trust_tunnel_cloudflared_config` | The whole remote config of one tunnel: `config.ingress[]` (`hostname`, `path`, `service`, `origin_request`) and a default `config.origin_request`. | No. |
| `cloudflare_dns_record` | `CNAME <host> -> <tunnel_id>.cfargotunnel.com`, `proxied = true`. | No. |
| `cloudflare_zero_trust_access_application` | `self_hosted` application per hostname (and path), referencing reusable policies. Its `aud` is the audience tag `cloudflared` checks. | No for `self_hosted`. |
| `cloudflare_zero_trust_tunnel_cloudflared_token` (data source) | Reads the connector token. | **Yes**: `token` is `computed` + `sensitive`, and data source results are stored in state **(verified, schema)**. Not used. |

Sources: registry docs for [`zero_trust_tunnel_cloudflared`](https://registry.terraform.io/providers/cloudflare/cloudflare/5.28.1/docs/resources/zero_trust_tunnel_cloudflared), [`zero_trust_tunnel_cloudflared_config`](https://registry.terraform.io/providers/cloudflare/cloudflare/5.28.1/docs/resources/zero_trust_tunnel_cloudflared_config), [`zero_trust_tunnel_cloudflared_token`](https://registry.terraform.io/providers/cloudflare/cloudflare/5.28.1/docs/data-sources/zero_trust_tunnel_cloudflared_token) **(verified)**.

Other provider facts:

- **No write-only attributes and no ephemeral resources exist in provider 5.28.1** (empty `write_only` list and empty `ephemeral_resource_schemas` in the schema dump) **(verified, schema)**. The latest release on the research date, 5.29.0 (2026-11-11), still documents `tunnel_secret` as a plain sensitive string and lists no ephemeral resources **(verified, registry)**.
- The Cloudflare [Terraform deployment guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/terraform/) for provider v5 creates the tunnel with `config_src = "cloudflare"` and no secret, then reads the token with the data source and passes it to the VM **(verified)**. That last step is exactly what the repo rule forbids.
- One `cloudflare_zero_trust_tunnel_cloudflared_config` owns the **whole** ingress list of a tunnel. Two roots cannot each own part of it (inferred from the resource shape: one resource per `tunnel_id`, `config.ingress` is a list).

### Tunnels, tokens and rotation

- A remotely-managed tunnel needs only its token to run, and "anyone with access to the token will be able to run the tunnel" ([tunnel permissions](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/), **verified**).
- The token comes from the dashboard, from `GET /accounts/{account_id}/cfd_tunnel/{tunnel_id}/token` (`result` field; needs `Cloudflare Tunnel Write` or a `Cloudflare One Connector(s) Write` permission), or from the Terraform data source (same page, **verified**).
- `POST /accounts/{account_id}/cfd_tunnel` with only `name` and `config_src` creates a tunnel; Cloudflare generates the secret and returns `token` and `credentials_file.TunnelSecret` in the response ([create a tunnel with the API](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel-api/), **verified**). The v5 resource keeps neither, since its schema has no such attribute.
- Rotation: `PATCH /accounts/{account_id}/cfd_tunnel/{tunnel_id}` with a new `tunnel_secret` (or "Refresh token" in the dashboard) returns the new token. The old token can no longer open new connections, existing connectors keep serving. With at least two replicas, roll them half at a time. For a compromised token, also `DELETE .../cfd_tunnel/{tunnel_id}/connections` (tunnel permissions page, **verified**).
- Whether a rotation through the API shows as drift on `cloudflare_zero_trust_tunnel_cloudflared` when `tunnel_secret` is omitted: expected not, since the attribute is not computed and stays null **(unverified)**.

### Remote vs local management

| | Remotely-managed (`config_src = "cloudflare"`) | Locally-managed (`config_src = "local"`) |
| --- | --- | --- |
| Credential in the cluster | One token string. | A credentials JSON with the tunnel secret, plus a `config.yaml`. |
| Who creates the credential | Cloudflare, at tunnel creation. | `cloudflared tunnel create` (needs the account-wide `cert.pem` from `cloudflared tunnel login`) or Terraform with `tunnel_secret` (in state) **(unverified for cert.pem scope)**. |
| Where the ingress lives | Cloudflare API, set by `cloudflare_zero_trust_tunnel_cloudflared_config` (or the dashboard). | A ConfigMap rendered into Git; GitOps-native. |
| DNS records | Separate `cloudflare_dns_record` (Terraform) either way. `cloudflared tunnel route dns` exists for local tunnels. |  |
| Dashboard | Shows and edits the config. | Config visible only on the host. |

Sources: [useful terms](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/tunnel-useful-terms/), [configuration file](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/), [Kubernetes guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/) **(verified)**. The Kubernetes guide uses a remotely-managed tunnel and points to an external example repository for the local variant **(verified)**.

The local mode's one advantage (ingress in Git) is mostly cancelled by the catch-all-to-Gateway design below: with routing in `HTTPRoute`s, the tunnel config barely changes. The local mode's cost is a secret that either Terraform state or an account-wide certificate must produce. **Remote wins.**

### Ingress rules and DNS

- Ingress rules are evaluated first to last; the last one must be a catch-all (for example `http_status:404`). Hostnames accept a leading wildcard (`*.example.com`), not one in the middle; `path` is a Go regular expression ([configuration file](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/), **verified** for local config; the same rule model for remote config is **unverified** beyond the `hostname`/`path`/`service` fields of the Terraform schema).
- A CNAME to `<UUID>.cfargotunnel.com` routes a hostname to the tunnel. That subdomain only proxies records of the same Cloudflare account. A stopped tunnel leaves the record in place and visitors get error 1016 ([DNS records](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/), **verified**). The API guide creates the record with `proxied: true` **(verified)**.
- Wildcard DNS records can be created and proxied on every plan; an exact record wins over the wildcard ([wildcard records](https://developers.cloudflare.com/dns/manage-dns-records/reference/wildcard-dns-records/), **verified**).
- **Universal SSL covers the apex and first-level subdomains only** in a full-setup zone. `a.b.gsuquet.com` gets no valid edge certificate without Advanced Certificate Manager (paid) or a custom certificate ([Universal SSL limitations](https://developers.cloudflare.com/ssl/edge-certificates/universal-ssl/limitations/), **verified**). This drives the hostname scheme.

### Origin connection settings

From [origin parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/origin-parameters/) **(verified)**:

- `noTLSVerify` defaults to `false`: `cloudflared` verifies the origin certificate. `true` accepts any certificate.
- `originServerName`: the name `cloudflared` expects in the origin certificate. `matchSNItoHost`: sets the SNI from the request host. `caPool`: extra CA file added to the default trust pool. `http2Origin`: HTTP/2 to an HTTPS origin. `httpHostHeader`: overrides `Host`.
- `access` (`required`, `teamName`, `audTag`): `cloudflared` validates the Access JWT before proxying.
- The registry description of `ca_pool` says it "should be used only if your certificate is not signed by Cloudflare", which implies `cloudflared` trusts Cloudflare Origin CA certificates by default **(unverified as a guarantee)**.

### Running `cloudflared` in Kubernetes

From the [Kubernetes guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/) **(verified)**:

- `replicas: 2` for availability, not for scaling; `cloudflared` does not load-balance across replicas, and scaling down can break open connections.
- Token in a Secret, injected as `TUNNEL_TOKEN` (not on the command line).
- `cloudflared tunnel --no-autoupdate --loglevel info --output json --metrics 0.0.0.0:2000 run`, liveness probe `GET /ready` on port 2000 (200 only with an active edge connection).
- A pod sysctl `net.ipv4.ping_group_range` for ICMP, only needed for private-network use.

Egress, from [tunnel with firewall](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/) **(verified)**: `region1.v2.argotunnel.com` and `region2.v2.argotunnel.com` on port 7844, TCP (`http2`) and UDP (`quic`). Optional on 443: `api.cloudflare.com` and `update.argotunnel.com` (update checks), `<team>.cloudflareaccess.com` (only with JWT validation), plus a DNS TXT lookup of `cfd-features.argotunnel.com`.

### Limits

From [account limits](https://developers.cloudflare.com/cloudflare-one/account-limits/) **(verified)**:

| Limit | Value | Relevance |
| --- | --- | --- |
| `cloudflared` tunnels per account | 1,000 | One per cluster is far below. |
| Active replicas per tunnel | 25 | Two per cluster. |
| Published applications per tunnel | Bounded by the 1 MB config size | Irrelevant with a catch-all rule. |
| Access applications | 500 | One per exposed platform UI plus public tenant hosts. |
| Reusable policies | 500 | Three today. |
| Domains per Access application | 50 | |

- Seats: any Access authentication event consumes a seat until the user is removed or expires ([seat management](https://developers.cloudflare.com/cloudflare-one/team-and-resources/users/seat-management/), **verified**). The Zero Trust Free plan allows 50 users **(unverified)**: the plans page is outside the allowed domains. Household and family logins count; anonymous visitors of a Bypass application do not **(unverified)**.
- Tunnels themselves have no separate charge on the Free plan **(unverified)**.

### Access policies

- Bypass "disables Access enforcement" and its requests "are not logged"; Service Auth enforces non-IdP authentication (service tokens, mTLS) and keeps logging ([policies](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/), **verified**).
- A more specific Access application (hostname and path) takes precedence over the `*.<domain>` catch-all **(unverified)**. The landing zone design already relies on this.

## Options

### 1. Tunnel per cluster vs shared

| | Tunnel per cluster | One shared tunnel |
| --- | --- | --- |
| Blast radius of a leaked token | One cluster's hostnames. | Every cluster: anyone with the token can attach a connector and receive traffic for every hostname. |
| Lifecycle | Created and destroyed with `clusters/<name>/`. | A landing-zone resource that outlives clusters. |
| Routing | DNS decides the cluster. | Cloudflare picks a connected replica; every cluster would have to serve every hostname. Only meaningful for active/active of identical clusters. |
| Migration olympus to Talos | Create the Talos tunnel, flip each CNAME one at a time, roll back by flipping back. | Connectors of both clusters mixed on one tunnel during the move: traffic split unpredictably. |
| Health | Per cluster in the dashboard and in the `status` attribute. | Mixed. |

**Choose one tunnel per cluster.**

### 2. Which Terraform root owns tunnel, config, DNS and Access

| Option | Pros | Cons |
| --- | --- | --- |
| A. Landing zone creates all tunnels | One Cloudflare root. | The landing zone would know every cluster; cluster lifecycle (`cluster:up/down`) would need a landing-zone apply. |
| **B. `clusters/<name>/` creates its tunnel, tunnel config, platform DNS records and platform Access applications** (via a `modules/cloudflare-tunnel` child module) | Lifecycle matches the cluster; state already at `clusters/<name>/terraform.tfstate`. | The cluster root needs a Cloudflare token (scope below) in addition to its infrastructure credentials. |
| C. Tunnel in the cluster root, tenant hostnames in a tenant root | Clean split of ownership. | There is no tenant Terraform root yet. Tenant hostnames need only DNS + Access, so a separate root is cheap to add later. |
| D. external-dns in the cluster creates CNAMEs from `HTTPRoute`s | GitOps-native, no Terraform for tenant hosts. | A DNS-write Cloudflare token lives in the cluster; any tenant whose route attaches to the edge Gateway can publish a name; Access applications still need Terraform. |

**Choose B now, and C for tenant hostnames** once a tenant needs a public name. The tenant root (or a `tenants` section of the cluster root, reading `gitops/tenants/<tenant>.yaml` with `yamldecode`) only adds `cloudflare_dns_record` and `cloudflare_zero_trust_access_application`, referencing the landing zone's policy IDs. The tunnel config does not change for a tenant, thanks to the catch-all rule.

Cluster roots look up the zone and the reusable policies with data sources rather than `terraform_remote_state`, so they do not need read access to the landing-zone state: `cloudflare_zone` takes a `filter` (name), `cloudflare_zero_trust_access_policies` takes only `account_id` and `max_items`, so the module lists the policies and picks them by name in a `local` **(verified, schema)**.

### 3. How the connector token reaches the cluster

| Option | Secret in state | Person step | Notes |
| --- | --- | --- | --- |
| a. `tunnel_secret` from `random_bytes` in Terraform | Yes (resource + `random_bytes`) | None | Violates the repo rule. |
| b. Token data source, pushed by Terraform into the backend | Yes (data source) | None | Violates the repo rule. |
| **c. Terraform creates the tunnel without a secret; a person-run task reads the token from the API and writes it into the backend** | No | One run per tunnel creation or rotation | Same pattern as the OAuth identity providers already kept out of Terraform. |
| d. A person creates the tunnel in the dashboard, Terraform imports it | No | Dashboard click + import | More manual than (c), no benefit. |
| e. Wait for a write-only `tunnel_secret_wo` or an ephemeral token resource | No | None | Does not exist in 5.28.1 or 5.29.0. Revisit at each provider bump. |

**Choose (c).** Shape of the task (name proposal: `mise run cluster:tunnel-token <name>`): read the tunnel ID from `terraform output`, call `GET /accounts/{account_id}/cfd_tunnel/{tunnel_id}/token` with a token from `pass-cli run`, and pipe the `result` straight into the secrets backend's CLI under `clusters/<name>/cloudflared/tunnel-token`, never to a file or the terminal. Only a person runs it, like `cf:ids`. The backend-specific write step waits for the secrets backend decision.

In the cluster, the `cloudflared` component ships:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cloudflared-tunnel-token
  namespace: cloudflared
spec:
  secretStoreRef:
    kind: SecretStore
    name: secrets
  target:
    name: cloudflared-tunnel-token
  data:
    - secretKey: token
      remoteRef:
        key: clusters/<name>/cloudflared/tunnel-token  # path scheme follows the backend decision
```

and the Deployment reads it as `TUNNEL_TOKEN` through `secretKeyRef`. The `external-secrets.io/v1` API version and the store kind follow whatever the ESO and secrets-backend work settles **(unverified here)**.

Rotation is the documented PATCH + rolling restart, wrapped in the same task (`--rotate`): generate the secret inside the task, PATCH, write the returned token into the backend, then let ESO refresh and restart the Deployment (or annotate it). Two replicas keep the tunnel up during the roll.

### 4. Routing `cloudflared` to the Gateway

| Option | Ingress rules | Change per new hostname |
| --- | --- | --- |
| a. One rule per hostname pointing at each backend Service (homelab model) | Grows with every app. | Tunnel config + DNS, no `HTTPRoute`. Bypasses the Gateway, its policies and its metrics. |
| b. One rule per hostname pointing at the Gateway Service | Grows with every app. | Tunnel config + DNS + `HTTPRoute`. |
| **c. A few explicit rules (platform UIs with JWT validation, webhook paths) + catch-all `service: https://<gateway-service>` with `matchSNItoHost`** | Static per cluster. | DNS (+ Access) + `HTTPRoute`. |

**Choose (c).** The catch-all replaces the usual `http_status:404`: a name with no matching `HTTPRoute` gets the Gateway's 404. Only names that have a proxied CNAME to this tunnel reach it at all, so the catch-all does not widen exposure: DNS is the exposure list, `HTTPRoute`s are the routing list.

Edge Gateway per cluster: one `Gateway` (name proposal `edge`, namespace `gateway`) with an HTTPS listener per exposed hostname or wildcard `*.gsuquet.com`, `allowedRoutes` restricted to namespaces carrying a label (platform namespaces + onboarded tenants). The Service that implementations create for a Gateway is implementation-specific: Cilium creates a `LoadBalancer` Service by default ([Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/), **verified**), named `cilium-gateway-<gateway>` **(unverified)**. Reaching that Service through its ClusterIP from a pod (what `cloudflared` does) needs a check on kind with Cilium **(unverified)**. `cluster.yaml` therefore carries the origin, rendered into nothing but the tunnel config:

```yaml
# gitops/clusters/<name>/cluster.yaml (excerpt, proposal)
exposure:
  tunnel: true
  origin: https://cilium-gateway-edge.gateway.svc.cluster.local:443
```

On GKE the catalog skips Cilium; the in-cluster Gateway implementation there is open (see the open questions). A GKE-managed `gke-l7-*` Gateway is a cloud load balancer, which a tunnel does not need.

### 5. TLS between `cloudflared` and the Gateway

The tunnel already encrypts edge to `cloudflared`. The question is the in-cluster hop and certificate verification.

| Option | Verification | Secret | Notes |
| --- | --- | --- | --- |
| a. Plain HTTP to the Gateway | None | None | Simplest. In-cluster hop in clear text unless Cilium transparent encryption is on. The Gateway still needs certificates if LAN clients reach it directly. |
| b. HTTPS + `noTLSVerify: true` | None | None | Encrypts but accepts any certificate. Rejected. |
| c. HTTPS with a Cloudflare Origin CA certificate | Implicit trust **(unverified)** | Private key: `cloudflare_origin_ca_certificate` takes a CSR whose key would come from `tls_private_key` in state, or the origin-ca-issuer controller with an Origin CA key in the cluster **(unverified)** | Not trusted by browsers, so useless for LAN clients. |
| **d. HTTPS with cert-manager certificates from Let's Encrypt (DNS-01 on Cloudflare), `matchSNItoHost: true`** | Full, against public roots | A Cloudflare API token limited to `Zone:DNS:Edit` on the zone, delivered through ESO `secrets` | Same certificate serves LAN clients. `cert-manager` is a baseline component. CAA already allows `letsencrypt.org`. |

**Choose (d)** for Talos and GKE, with (a) acceptable as a first step until cert-manager's DNS-01 issuer exists. The DNS-01 token is created by a person (dashboard) and stored in the backend, not by a Terraform resource; scoping it to `_acme-challenge` records is not possible with Cloudflare API token permissions **(unverified)**.

### 6. Access in front of internal apps

The landing zone's `*.<domain>` catch-all already requires a `household-standard` login for any name without a more specific application. Per cluster root:

| Hostname | Access application | Policy | `cloudflared` JWT check |
| --- | --- | --- | --- |
| `argocd-<cluster>.gsuquet.com` | `self_hosted` | `owner-sensitive` | `access.required = true`, `aud_tag` = the application's `aud` |
| `argocd-<cluster>.gsuquet.com/api/webhook` | `self_hosted` with path | Bypass (GitHub cannot present an Access token), relying on Argo CD's webhook secret (HMAC) | No |
| `kargo-<cluster>.gsuquet.com` | `self_hosted` | `owner-sensitive` | Yes |
| Kargo webhook receiver path | `self_hosted` with path | Bypass, relying on the receiver's secret | No |
| Public tenant host | `self_hosted` | Bypass (everyone) | No |

- Argo CD and Kargo keep their own SSO behind Access: Access is the outer gate, not the identity source. Using Access as the OIDC provider (SaaS application) would remove one login, but `saas_app.client_secret` is `computed` + `sensitive` in 5.28.1, so it would land in Terraform state **(verified, schema)**: out under the repo rule.
- CLI access: `argocd` and `kargo` CLIs behind Access need either `cloudflared access` login or an Access service token sent as headers **(unverified for both CLIs)**. The alternative is the CLI over a LAN or `kubectl port-forward` path, with Access only on the browser path.
- The webhook Bypass path is not logged by Access (verified above). A Service Auth policy cannot be used by GitHub webhooks, which send no custom headers **(unverified)**.

### Hostname scheme

Universal SSL covers one level: platform UIs are `<app>-<cluster>.gsuquet.com`; tenant production hosts are `<app>.gsuquet.com` (one cluster owns a given name at a time, chosen by its CNAME). A cluster-scoped subdomain (`*.olympus.gsuquet.com`) would need Advanced Certificate Manager.

## Proposed design

```text
                    Cloudflare edge (TLS, WAF, Access)
                                │  QUIC/HTTP2 :7844, outbound only
           ┌────────────────────┴─────────────────────┐
           │ cluster <name>                            │
           │  ns cloudflared: Deployment x2            │
           │    TUNNEL_TOKEN <- ESO store "secrets"    │
           │        │ HTTPS, SNI = request host        │
           │  ns gateway: Gateway "edge" (cert-manager)│
           │        │ HTTPRoutes (platform + tenants)  │
           │  apps                                     │
           └───────────────────────────────────────────┘
```

1. **`modules/cloudflare-tunnel/`** (child module, used by `clusters/<name>/` for Talos and GKE):
   - `cloudflare_zero_trust_tunnel_cloudflared` `<cluster>`, `config_src = "cloudflare"`, no `tunnel_secret`.
   - `cloudflare_zero_trust_tunnel_cloudflared_config`: explicit rules for hostnames with `access_required`, then catch-all to `var.origin` with `origin_request.match_sn_ito_host = true` (`no_tls_verify` stays `false`).
   - `cloudflare_dns_record` per platform hostname: `CNAME`, `content = "${tunnel.id}.cfargotunnel.com"`, `proxied = true`, `ttl = 1`.
   - `cloudflare_zero_trust_access_application` per platform hostname/path, policies looked up by name.
   - Outputs: tunnel ID (not secret), hostnames.
2. **Cloudflare credentials for cluster roots**: a new Pass item scoped to `Cloudflare Tunnel Write` on the account, `Zone:DNS:Edit` on the zone and Access applications write, distinct from the landing zone's account-wide write token. Exact permission names to confirm in the dashboard **(unverified)**.
3. **`gitops/components/cloudflared/`**: Deployment (2 replicas, pinned image digest, the flags of the Kubernetes guide, `/ready` probe, non-root, read-only root FS as in homelab), `ExternalSecret` from store `secrets`, `CiliumNetworkPolicy` allowing egress to `world` on 7844 TCP/UDP (`toFQDNs` on `*.v2.argotunnel.com` needs the Cilium DNS proxy; start with `toEntities: [world]` on port 7844) and on 443 to the team domain, plus egress to the Gateway. `PodDisruptionBudget` `minAvailable: 1`.
4. **Person-run task** `cluster:tunnel-token <name> [--rotate]` (section 3).
5. **kind**: `cloudflared` not enabled. For a demo, a separate tunnel (`dev-<user>`) can be created by hand; not part of the platform.
6. **Migration from olympus**: keep olympus's hand-made tunnel untouched. Create the Talos cluster's tunnel in its root, then for each hostname: remove the public hostname from the olympus tunnel in the dashboard (which owns the dashboard-created DNS record), let the Talos root create the record, verify. Hostnames move to the `<app>-<cluster>` or `<app>` scheme at the same time if they are deeper than one level. When olympus is gone, delete its tunnel in the dashboard.

## Open questions

1. **Credentials split**: is a dedicated Cloudflare API token for cluster roots (tunnel + DNS + Access applications) acceptable, or should cluster roots reuse the landing zone's write token?
2. **Tenant hostnames**: separate tenant Terraform root (option C), or a `tenants` section in each cluster root reading `gitops/tenants/*.yaml`? external-dns (option D) is rejected here; confirm.
3. **Public tenant apps**: is a Bypass Access application per public hostname the right default, given the landing-zone catch-all? Or should public hosts live on a separate domain without a catch-all?
4. **TLS first step**: accept plain HTTP from `cloudflared` to the Gateway until the cert-manager DNS-01 issuer exists, or block exposure on it?
5. **GKE origin**: which in-cluster Gateway implementation on GKE (Dataplane V2, no Cilium Gateway): Envoy Gateway, or another catalog entry? Or does GKE expose through a GKE Gateway and not use a tunnel at all?
6. **CLI access** to Argo CD and Kargo: through Access (`cloudflared access` / service token), or LAN / port-forward only?
7. **Free plan seats**: confirm the 50-user Free plan limit (could not be verified from allowed domains) against household and family use.
8. **Provider bumps**: who watches for a write-only `tunnel_secret_wo` or an ephemeral token resource? If one appears, option (e) removes the person-run step; a Renovate PR note or a TODO in the module is proposed.

## To verify before implementation

- Cilium Gateway Service name and ClusterIP reachability from a pod on kind (throwaway cluster).
- No drift on `cloudflare_zero_trust_tunnel_cloudflared` after an API rotation.
- Access application precedence of hostname+path over `*.<domain>`.
- Argo CD and Kargo webhook secrets and CLI behaviour behind Access.
