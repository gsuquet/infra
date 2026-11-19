# Cloudflare Tunnel exposure study

Status: proposal, input for a future ADR. Research date: 2026-11-18, revised 2026-11-19 after review.

This study decides how each cluster exposes HTTP services to the internet through Cloudflare Tunnel. It covers the tunnel layout, the Terraform resources, where the connector token lives, how `cloudflared` reaches a Gateway API Gateway, TLS to the origin, Access in front of the platform UIs, and which Terraform root owns what.

Facts marked **(verified)** were checked on the date above against the source linked next to them, or against the provider schema (`terraform providers schema -json` with `cloudflare/cloudflare` 5.28.1, the version pinned in `landing-zone/cloudflare/terraform.tf`). Facts marked **(unverified)** come from prior knowledge or from a source outside the allowed documentation domains. Check them before you build on them.

## Summary

- **One remotely-managed tunnel per cluster** (`config_src = "cloudflare"`), created by the cluster's Terraform root `clusters/<name>/`. No tunnel for kind by default.
- **No `tunnel_secret` in Terraform.** Cloudflare generates the secret. Provider 5.28.1 has no write-only argument and no ephemeral resource for tunnels, and the `cloudflare_zero_trust_tunnel_cloudflared_token` data source would put the token in state. So the token never goes through Terraform: a person-run task reads it from the API and writes it into the secrets backend, and ESO delivers it from the store `secrets`.
- **The tunnel ingress is almost static**: platform hostnames that need `cloudflared` JWT validation get their own rule, and one catch-all rule sends everything else to the cluster's edge Gateway Service. Host routing happens in `HTTPRoute`s, not in the tunnel config. A tenant hostname therefore needs only a DNS record (and, when it must be public, an Access application), never a tunnel config change.
- **The edge Gateway is reachable only through the tunnel.** No LAN IP, no node port, and a Cilium policy that admits only `cloudflared` into the Gateway. Otherwise Access is bypassed from the LAN. LAN access, if wanted, is a separate internal Gateway that does not go through Access.
- **Hostnames are bound to owners in the Gateway, not by creation order.** One listener per owner (platform, each tenant) with exact hostnames from `gitops/tenants/<tenant>.yaml` and `allowedRoutes` limited to that owner's namespaces.
- **TLS**: Cloudflare terminates TLS at the edge. `cloudflared` talks HTTPS to the Gateway and verifies a certificate from an in-cluster cert-manager CA (`caPool`). No Cloudflare DNS token in the cluster. `noTLSVerify` is not used.
- **Access**: the landing zone's catch-all Access application on `*.<domain>` already denies by default. Argo CD and Kargo UIs get their own Access application with the `owner-sensitive` policy, plus `cloudflared` JWT validation. Git webhooks are off by default (polling); no Bypass path is opened unless a cluster opts in.
- **`cloudflared` targets Talos first.** On GKE it stays out of scope until the GKE Gateway implementation and network-policy flavour are settled.
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
| Default-deny `CiliumClusterwideNetworkPolicy` on every labelled namespace. | The `cloudflared` namespace needs explicit egress to Cloudflare (port 7844) and to the Gateway. Cilium's Gateway has no pods: Envoy enforces it under the reserved `ingress` identity, so policy is written against that identity (see section 4). |
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
- A more specific Access application (hostname and path) takes precedence over the `*.<domain>` catch-all **(unverified)**. The landing zone design already relies on this for exact hostnames; this study no longer relies on path-level precedence by default (see section 6).

## Options

### 1. Tunnel per cluster vs shared

| | Tunnel per cluster | One shared tunnel |
| --- | --- | --- |
| Blast radius of a leaked token | One cluster's hostnames. | Every cluster: anyone with the token can attach a connector and receive traffic for every hostname. |
| Lifecycle | Created and destroyed with `clusters/<name>/`. | A landing-zone resource that outlives clusters. |
| Routing | DNS decides the cluster. | Cloudflare picks a connected replica; every cluster would have to serve every hostname. Only meaningful for active/active of identical clusters. |
| Migration olympus to Talos | Create the Talos tunnel, import each existing CNAME into the Talos root and change its target in one apply, roll back by reverting the target. | Connectors of both clusters mixed on one tunnel during the move: traffic split unpredictably. |
| Health | Per cluster in the dashboard and in the `status` attribute. | Mixed. |

**Choose one tunnel per cluster.**

### 2. Which Terraform root owns tunnel, config, DNS and Access

| Option | Pros | Cons |
| --- | --- | --- |
| A. Landing zone creates all tunnels | One Cloudflare root. | The landing zone would know every cluster; cluster lifecycle (`cluster:up/down`) would need a landing-zone apply. |
| **B. `clusters/<name>/` creates its tunnel, tunnel config, platform DNS records and platform Access applications** (via a `modules/cloudflare-tunnel` child module) | Lifecycle matches the cluster; state already at `clusters/<name>/terraform.tfstate`. | The cluster root needs a Cloudflare token (scope below) in addition to its infrastructure credentials. |
| C. Tunnel in the cluster root, tenant hostnames in a separate tenant root | Clean split of ownership. | Adds a Terraform root outside the settled layout (`landing-zone/`, `modules/`, `clusters/<name>/`); it would need the tunnel ID through `terraform_remote_state` or a data source lookup by name, and would hold CNAMEs that dangle when `cluster:down` deletes the tunnel. |
| D. external-dns in the cluster creates CNAMEs from `HTTPRoute`s | GitOps-native, no Terraform for tenant hosts. | A zone-wide DNS-write Cloudflare token lives in the cluster (it can repoint MX and every tunnel CNAME); any tenant whose route attaches to the edge Gateway can publish a name; Access applications still need Terraform. |

**Choose B, including tenant hostnames.** The cluster root takes its tenant hostnames from `gitops/tenants/<tenant>.yaml`, the same file the render step uses for the Gateway listeners (section 4), so one list feeds both DNS and routing. Terraform reads it with `yamldecode(file(...))` relative to the repository root; this coupling of a Terraform root to gitops files is deliberate and limited to read-only inputs (`tenants` list from `gitops/clusters/<name>/cluster.yaml`, `hostnames` per tenant). Per tenant hostname the root adds `cloudflare_dns_record` and, if needed, `cloudflare_zero_trust_access_application`. The tunnel config does not change for a tenant, thanks to the catch-all rule.

Consequences:

- Tenant CNAMEs share the cluster's state, so they always point at a tunnel that exists. `cluster:down` destroys them with the tunnel: a tenant's public hostname goes down with its cluster. Moving a hostname to another cluster is the import-and-flip of design item 6 (the old root then drops it with a `removed` block so the record is not destroyed).
- A hostname owned by two clusters at once is impossible by construction (one DNS record, one state); a check in `manifests:check` should fail if two clusters list the same tenant hostname.
- The landing-zone README says "Access applications belong to the tenant layer". Proposed README edit (separate PR, outside this study's file scope): "Access applications for a cluster's platform UIs and its tenants' hostnames belong to that cluster's root `clusters/<name>/`; the landing zone keeps the catch-all application and the reusable policies".

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

**Choose (c).** The catch-all replaces the usual `http_status:404`: a name with no matching `HTTPRoute` gets the Gateway's 404. Only names that have a proxied CNAME to this tunnel reach it at all, so the catch-all does not widen exposure at the DNS level. It does make the Gateway's route attachment the place where hostnames are claimed, so the Gateway must bind hostnames to owners (below).

#### The edge Gateway is reachable only through the tunnel

Access protects only traffic that goes through Cloudflare. If the edge Gateway also has a LAN address, every hostname on it, the platform UIs included, is reachable from the LAN without Access, and the `cloudflared` JWT check does not run either. So:

- Cilium creates a `LoadBalancer` Service per Gateway by default, named `cilium-gateway-<gateway>`; `CiliumGatewayClassConfig` (`cilium.io/v2alpha1`, referenced from the GatewayClass `parametersRef`) sets `spec.service`, but `type` accepts **only `LoadBalancer` and `NodePort`, not `ClusterIP`** ([Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/), [parameterized GatewayClass](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/parameterized-gatewayclass/), **verified**). A ClusterIP-only edge Gateway is therefore not available through the Cilium API.
- What the design does instead, on its own `GatewayClass` `cilium-edge` with a `CiliumGatewayClassConfig`:
  - `service.allocateLoadBalancerNodePorts: false`, so no node port exists.
  - No external IP: the cluster's `CiliumLoadBalancerIPPool`s select Services by label, and the edge Gateway's Service matches none of them (or `service.loadBalancerClass` names a class no controller serves), so the Service stays `<pending>` and is reachable only by its ClusterIP **(unverified: whether Cilium's Gateway Envoy listener still works with a pending LoadBalancer; verify on kind)**.
  - A `CiliumClusterwideNetworkPolicy` that allows the reserved `ingress` identity to receive traffic only from the `cloudflared` endpoints (and not from `world`), since Cilium enforces Gateway traffic at the `ingress` identity ([Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/), **verified** that the identity exists; the exact policy shape is **unverified**).
- If LAN access is wanted, it is a **separate internal Gateway** (`lan`, own GatewayClass with an LB IPAM pool) with its own listeners. It does not go through Access, and platform UIs are attached to it only by explicit decision (open question 9).

#### Hostnames are bound to owners

Gateway API resolves conflicting `HTTPRoute`s by creation time, not by owner, and `allowedRoutes` filters only by namespace. A wildcard `*.gsuquet.com` listener open to every onboarded tenant would let any tenant claim `argocd-<cluster>.gsuquet.com` or another tenant's hostname. The edge Gateway therefore has:

- One `platform` HTTPS listener per platform hostname (or one listener with several exact hostnames if the implementation allows it; Gateway API listeners take a single `hostname`), `allowedRoutes.namespaces` selecting only platform namespaces (`argocd`, `kargo`) by a label tenants cannot set.
- One listener per tenant hostname, `hostname` exact, `allowedRoutes.namespaces` selecting only that tenant's namespaces (by the tenant label infra puts on namespaces it creates). The render step generates these listeners from `gitops/tenants/<tenant>.yaml` (`hostnames:`), which is also what Terraform reads for DNS (section 2).
- No wildcard listener.

Tenants cannot set the selecting label on their namespaces because infra creates those namespaces and the AppProject forbids cluster-scoped resources. Gateway API caps a Gateway at 64 listeners **(unverified)**; past that, a second edge Gateway per cluster or a `ListenerSet` **(unverified, experimental)**.

A Conftest rule on tenant `HTTPRoute.spec.hostnames` would be a second layer, but tenant manifests live in `gsuquet/gitops`, outside this repository's CI; an admission rule (ValidatingAdmissionPolicy) in the cluster could enforce it instead. Listener binding is the primary control.

#### Origin URL

The origin is a Terraform input of the cluster root (`var.tunnel_origin`, default `https://cilium-gateway-edge.gateway.svc.cluster.local:443`), not a field rendered from `cluster.yaml`: the tunnel config is Terraform, and the cluster root already reads the tenant files only for hostnames. `cluster.yaml` only enables the `cloudflared` component.

On GKE the catalog skips Cilium; the in-cluster Gateway implementation there is open (see the open questions). A GKE-managed `gke-l7-*` Gateway is a cloud load balancer, which a tunnel does not need.

### 5. TLS between `cloudflared` and the Gateway

The tunnel already encrypts edge to `cloudflared`. The question is the in-cluster hop and certificate verification.

| Option | Verification | Secret | Notes |
| --- | --- | --- | --- |
| a. Plain HTTP to the Gateway | None | None | Simplest. In-cluster hop in clear text unless Cilium transparent encryption is on. |
| b. HTTPS + `noTLSVerify: true` | None | None | Encrypts but accepts any certificate. Rejected. |
| c. HTTPS with a Cloudflare Origin CA certificate | Implicit trust **(unverified)** | Private key: `cloudflare_origin_ca_certificate` takes a CSR whose key would come from `tls_private_key` in state, or the origin-ca-issuer controller with an Origin CA key in the cluster **(unverified)** | Not trusted by browsers, so useless for LAN clients. |
| d. HTTPS with cert-manager certificates from Let's Encrypt (DNS-01 on Cloudflare), `matchSNItoHost: true` | Full, against public roots | A Cloudflare API token with `Zone:DNS:Edit` on the zone, in the cluster through ESO `secrets` | A compromised cert-manager or ESO can repoint any record (MX, tunnel CNAMEs). The same objection that rejects external-dns (option 2D). |
| d'. As (d), with `_acme-challenge.<host>` CNAMEs delegated to a separate challenge-only zone | Full, against public roots | `Zone:DNS:Edit` on the challenge zone only | cert-manager follows CNAMEs for DNS-01 **(unverified)**; needs one more zone and one CNAME per hostname, managed by the cluster root. |
| **e. HTTPS with a certificate from an in-cluster cert-manager CA issuer; `cloudflared` trusts that CA through `caPool` and checks the name through `matchSNItoHost`** | Full, against the cluster CA | None outside the cluster: the CA key is generated by cert-manager in the cluster | Public trust is not needed once the edge Gateway serves only `cloudflared` (section 4). `caPool` is a file path in the `cloudflared` container: the CA bundle is mounted from a Secret or a trust-manager bundle. That a remotely-managed config's `caPool` path resolves on the connector's filesystem is **unverified**. |

**Choose (e)**, with (a) acceptable as a first step until the CA issuer exists. It keeps every DNS-write token out of the cluster, consistent with rejecting external-dns. A LAN Gateway (if any) is what would need publicly trusted certificates; then (d') is the preferred route, decided with open question 9. The external-dns rejection and the DNS-01 choice must be made together (open question 4).

### 6. Access in front of internal apps

The landing zone's `*.<domain>` catch-all already requires a `household-standard` login for any name without a more specific application. Per cluster root:

| Hostname | Access application | Policy | `cloudflared` JWT check |
| --- | --- | --- | --- |
| `argocd-<cluster>.gsuquet.com` | `self_hosted` | `owner-sensitive` | `access.required = true`, `aud_tag` = the application's `aud` |
| `kargo-<cluster>.gsuquet.com` | `self_hosted` | `owner-sensitive` | Yes |
| Public tenant host | `self_hosted` | Bypass (everyone) | No |

**Git webhooks are off by default.** With rendered manifests, Argo CD's default polling (every three minutes, [Argo CD webhooks](https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/), **verified**) and Kargo warehouse polling are enough. Opening `/api/webhook` exposes part of Argo CD's API server to the internet, and a Bypass application is not logged. Argo CD's webhook secret is optional ("Argo CD will still refresh applications ... even with unauthenticated webhook events"), the endpoint "currently lacks rate limiting protection", and the docs recommend a secret when Argo CD is publicly reachable (same page, **verified**).

If a cluster opts in:

- Argo CD: an Access application on `argocd-<cluster>.gsuquet.com` path `/api/webhook` with Bypass, which depends on path-over-hostname precedence **(unverified)**. The webhook secret (`webhook.github.secret`) is mandatory and comes from ESO store `secrets`; `webhook.maxPayloadSizeMB` is lowered.
- Kargo: webhook receivers are served by a separate external-webhooks server with its own Service, not under the UI host **(unverified: docs.kargo.io is outside the allowed domains)**. They get their own hostname `kargo-hooks-<cluster>.gsuquet.com`, their own platform listener and a hostname-level Bypass application, so no path precedence is needed. The receiver secret comes from ESO.

- Argo CD and Kargo keep their own SSO behind Access: Access is the outer gate, not the identity source. Using Access as the OIDC provider (SaaS application) would remove one login, but `saas_app.client_secret` is `computed` + `sensitive` in 5.28.1, so it would land in Terraform state **(verified, schema)**: out under the repo rule.
- CLI access: `argocd` and `kargo` CLIs behind Access need either `cloudflared access` login or an Access service token sent as headers **(unverified for both CLIs)**. The alternative is the CLI over a LAN or `kubectl port-forward` path, with Access only on the browser path.
- A Bypass path is not logged by Access (verified above). A Service Auth policy cannot be used by GitHub webhooks, which send no custom headers **(unverified)**.

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

1. **`modules/cloudflare-tunnel/`** (child module, used by `clusters/<name>/` on Talos; GKE once open question 5 is settled):
   - `cloudflare_zero_trust_tunnel_cloudflared` `<cluster>`, `config_src = "cloudflare"`, no `tunnel_secret`.
   - `cloudflare_zero_trust_tunnel_cloudflared_config`: explicit rules for hostnames with `access_required`, then catch-all to `var.origin` with `origin_request.match_sn_ito_host = true` (`no_tls_verify` stays `false`).
   - `cloudflare_dns_record` per platform and tenant hostname: `CNAME`, `content = "${tunnel.id}.cfargotunnel.com"`, `proxied = true`, `ttl = 1`.
   - `cloudflare_zero_trust_access_application` per platform hostname (and per tenant hostname that needs one), policies looked up by name.
   - Outputs: tunnel ID (not secret), hostnames.
2. **Cloudflare credentials for cluster roots**: a new Pass item with `Cloudflare Tunnel Write` on the account, `Zone:DNS:Edit` on the zone and Access applications write. Exact permission names to confirm in the dashboard **(unverified)**. Limit: Access application and policy edit rights are account-wide, so this token can also change the landing zone's catch-all application and reusable policies. It isolates tunnel and DNS work from the landing zone's other rights (zones, DNSSEC, IdPs, Zero Trust org), not Access (open question 1).
3. **`gitops/components/cloudflared/`**: Deployment (2 replicas, pinned image digest, the flags of the Kubernetes guide, `/ready` probe, non-root, read-only root FS as in homelab), `ExternalSecret` from store `secrets`, `PodDisruptionBudget` `minAvailable: 1`, the CA bundle mount for `caPool`, and a network policy whose flavour depends on the cluster's network implementation:
   - kind/Talos (Cilium): `CiliumNetworkPolicy` allowing egress to `world` on 7844 TCP/UDP (`toFQDNs` on `*.v2.argotunnel.com` needs the Cilium DNS proxy; start with `toEntities: [world]` on port 7844), 443 to the team domain, and egress to the edge Gateway (the `ingress` identity); plus the cluster-level policy of section 4 that admits only `cloudflared` into the edge Gateway, and allows `ingress` to backends.
   - GKE (Dataplane V2, no Cilium CRDs): a Kubernetes `NetworkPolicy` with egress on 7844/443 by CIDR, or GKE `FQDNNetworkPolicy` **(unverified)**. Shipping a `CiliumNetworkPolicy` there would fail the Argo CD sync. Until open question 5 is settled, `cloudflared` is not offered on GKE: the catalog marks it as unsupported there, as it does for `cilium`.
4. **Person-run task** `cluster:tunnel-token <name> [--rotate]` (section 3).
5. **kind**: `cloudflared` not enabled. For a demo, a separate tunnel (`dev-<user>`) can be created by hand; not part of the platform.
6. **Migration from olympus**, without a DNS gap: keep olympus's hand-made tunnel untouched. Create the Talos cluster's tunnel in its root (its catch-all already serves any hostname) and the matching listener and `HTTPRoute` on the Talos side. Then, per hostname:
   1. Add an `import` block for the existing dashboard-created CNAME to the Talos root, with `content` already set to the Talos tunnel. One `plan`/`apply` (run by the owner) imports and repoints the record in place: an atomic flip.
   2. Verify. Rollback is reverting `content` to the olympus tunnel ID and applying.
   3. Only then remove the public hostname from the olympus tunnel config in the dashboard. Whether the dashboard deletes the DNS record it created when the public hostname is removed is **unverified** (Cloudflare documents only that "The DNS record and the tunnel are independent" and that a stopped tunnel leaves the record in place); check that the record is still in the Talos root's plan as unchanged afterwards.
   Hostnames deeper than one level are renamed to the `<app>-<cluster>` or `<app>` scheme as new records instead (no flip possible). When olympus is gone, delete its tunnel in the dashboard.

## Open questions

1. **Credentials split**: a dedicated Cloudflare API token for cluster roots (tunnel + DNS + Access applications) still carries account-wide Access edit rights, so it can change the landing zone's catch-all application and policies. Accept that risk, or keep platform Access applications in a root that already has those rights (the landing zone, at the cost of it knowing every cluster)?
2. **Tenant hostnames**: the proposal is cluster root + `gitops/tenants/<tenant>.yaml` `hostnames` (option B). Confirm, and confirm that a tenant's public hostname goes down with `cluster:down`.
3. **Public tenant apps**: is a Bypass Access application per public hostname the right default, given the landing-zone catch-all? Or should public hosts live on a separate domain without a catch-all?
4. **DNS-write tokens in the cluster**: the proposal keeps them out entirely (in-cluster CA for the tunnel hop, no external-dns). If publicly trusted in-cluster certificates are needed later (LAN Gateway), choose between a delegated challenge zone (d'), HTTP-01 through the tunnel (needs a Bypass on `/.well-known/acme-challenge/` per host), or accepting a zone-wide token, and revisit external-dns with the same answer. Also: accept plain HTTP to the Gateway as a first step until the CA issuer exists?
5. **GKE origin**: which in-cluster Gateway implementation on GKE (Dataplane V2, no Cilium Gateway): Envoy Gateway, or another catalog entry? Or does GKE expose through a GKE Gateway and not use a tunnel at all?
6. **CLI access** to Argo CD and Kargo: through Access (`cloudflared access` / service token), or LAN / port-forward only?
7. **Free plan seats**: confirm the 50-user Free plan limit (could not be verified from allowed domains) against household and family use.
8. **Provider bumps**: who watches for a write-only `tunnel_secret_wo` or an ephemeral token resource? If one appears, option (e) removes the person-run step; a Renovate PR note or a TODO in the module is proposed.
9. **LAN access**: is a separate `lan` Gateway wanted at all, and may platform UIs attach to it (they would then skip Access)?
10. **Git webhooks**: polling by default is proposed; which clusters, if any, opt in?

## To verify before implementation

- On kind with Cilium (throwaway cluster): the edge Gateway with `allocateLoadBalancerNodePorts: false` and no matching LB IPAM pool still serves on its ClusterIP from a pod, and is unreachable from the host network.
- With the default-deny CCNP on kind: the policies needed for `cloudflared` to the Gateway, for `world` to be refused at the `ingress` identity, and for the `ingress` entity to reach backends.
- Per-owner listeners: a tenant `HTTPRoute` naming a platform or another tenant's hostname is not attached (`Accepted=False`).
- `caPool` in a remotely-managed tunnel config reads a file mounted in the `cloudflared` container.
- No drift on `cloudflare_zero_trust_tunnel_cloudflared` after an API rotation.
- Import-and-flip of a dashboard-created CNAME, and whether removing a public hostname in the dashboard deletes its DNS record.
- Access application precedence of hostname+path over `*.<domain>` (only if Argo CD webhooks are enabled).
- Kargo external webhook server Service and hostname; Argo CD and Kargo CLI behaviour behind Access.
