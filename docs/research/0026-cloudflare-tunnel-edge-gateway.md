# Edge Gateway, ingress rules and TLS

Explicit rules for JWT-validated platform hosts, then a catch-all, send requests to one Gateway that admits only
`cloudflared`, over HTTPS with a cluster CA.

Detail of [RFC 0026](../rfc/0026-cloudflare-tunnel.md), which defines the [verified and unverified marks](../rfc/0026-cloudflare-tunnel.md#context).

## Ingress rules and the edge Gateway

| Option | Rules | Change per new hostname | Verdict |
| --- | --- | --- | --- |
| One rule per hostname to each backend Service (homelab) | Grow | Tunnel config + DNS; bypasses the Gateway | Rejected |
| One rule per hostname to the Gateway | Grow | Tunnel config + DNS + `HTTPRoute` | Rejected |
| **Explicit rules for JWT-validated platform hosts, then catch-all to the Gateway with `match_sn_ito_host`** | Static | DNS (+ Access) + `HTTPRoute` | **Chosen** |

- The catch-all replaces `http_status:404`: a host without route gets the Gateway's 404. Only names with a proxied
  CNAME to this tunnel reach it, so DNS exposure does not widen; route attachment becomes where names are claimed.
- Origin: `var.tunnel_origin`, default `https://cilium-gateway-edge.gateway.svc.cluster.local:443`, an IaC input
  (not rendered from `cluster.yaml`, which only enables the component).
- Edge Gateway on its own GatewayClass `cilium-edge` with a `CiliumGatewayClassConfig`. Its `service.type` accepts
  only `LoadBalancer` or `NodePort`, not `ClusterIP`
  ([parameterized GatewayClass](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/parameterized-gatewayclass/),
  **verified**), so:

| Control | Setting |
| --- | --- |
| No node port | `service.allocateLoadBalancerNodePorts: false` |
| No external IP | No `CiliumLoadBalancerIPPool` selects the Service (or `loadBalancerClass` names an unserved class); it stays `<pending>`, reachable by ClusterIP only **(unverified: Envoy listener with a pending LB)** |
| Only `cloudflared` gets in | `CiliumClusterwideNetworkPolicy` on the reserved `ingress` identity: from `cloudflared` endpoints, not `world` (identity **verified**, [Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/); policy shape **unverified**) |
| Hostnames bound to owners | One `platform` listener per platform hostname, `allowedRoutes` selecting `argocd`, `kargo` by a label tenants cannot set; one listener per tenant hostname (exact, rendered from `gitops/tenants/<tenant>.yaml`) selecting that tenant's namespaces by the infra tenant label; no wildcard listener |

- Gateway API resolves conflicting `HTTPRoute`s by creation time and `allowedRoutes` filters only by namespace,
  hence per-owner listeners. Tenants cannot set the selecting label: infra creates their namespaces and the
  AppProject forbids cluster-scoped resources.
- Listeners per Gateway are limited: see the [listener risk](../rfc/0026-cloudflare-tunnel.md#drawbacks-and-risks).
- Second layer: a `ValidatingAdmissionPolicy` on tenant `HTTPRoute.spec.hostnames` (tenant manifests live in
  `gsuquet/gitops`, outside this repository's Conftest).
- A LAN Gateway, if wanted, is a separate `lan` Gateway with its own GatewayClass and LB IPAM pool, outside Access.

## TLS from cloudflared to the Gateway

| Option | Verification | Credential | Verdict |
| --- | --- | --- | --- |
| Plain HTTP | None | None | Accepted as a first step until the CA issuer exists |
| HTTPS + `noTLSVerify: true` | None | None | Rejected |
| Cloudflare Origin CA certificate | Implicit trust **(unverified)** | Key from `tls_private_key` in state, or origin-ca-issuer with an Origin CA key in the cluster **(unverified)** | Rejected: secret, not browser-trusted |
| Let's Encrypt DNS-01, `matchSNItoHost` | Public roots | Zone-wide `DNS Write` token in the cluster | Rejected: same objection as external-dns |
| Let's Encrypt DNS-01 via a delegated challenge zone | Public roots | `DNS Write` on the challenge zone only; cert-manager follows CNAMEs **(unverified)** | Preferred route if a LAN Gateway needs public trust |
| **In-cluster cert-manager CA; `cloudflared` trusts it via `caPool`, checks names via `matchSNItoHost`** | Cluster CA | None outside the cluster | **Chosen** |

- `caPool` is a file path in the container (CA bundle mounted from a Secret or a trust-manager bundle); that a
  remote config's `caPool` resolves on the connector's filesystem is **unverified**. `noTLSVerify` stays `false`.
- The `ca_pool` registry text ("only if your certificate is not signed by Cloudflare") implies default trust of
  Origin CA **(unverified as a guarantee)**.

## Public certificates later

Routes for the [DNS-write tokens question](../rfc/0026-cloudflare-tunnel.md#open-questions), if publicly trusted in-cluster certificates are needed
later (LAN Gateway): delegated challenge zone, HTTP-01 through the tunnel (Bypass on
`/.well-known/acme-challenge/` per host) or a zone-wide token.
