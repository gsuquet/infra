# The cloudflared component

Two `cloudflared` replicas run per cluster, with egress limited to the ports they need.

Detail of [RFC 0026](../rfc/0026-cloudflare-tunnel.md), which defines the [verified and unverified marks](../rfc/0026-cloudflare-tunnel.md#context).

<!-- readability: allow-code L3 L4 L7 V2 -->

## Deployment and egress

- Deployment, 2 replicas (availability, not load-balancing; scaling down can break open connections), pinned
  digest, non-root, read-only root FS, `TUNNEL_TOKEN` from the Secret,
  `tunnel --no-autoupdate --loglevel info --output json --metrics 0.0.0.0:2000 run`, liveness `GET /ready` on 2000
  (200 only with an edge connection); `PodDisruptionBudget` `minAvailable: 1`; no ICMP sysctl (private networks only)
  ([Kubernetes guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/),
  **verified**).
- Egress ([tunnel with firewall](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/),
  **verified**): `region1|region2.v2.argotunnel.com` on 7844 TCP (`http2`) and UDP (`quic`); 443 to
  `<team>.cloudflareaccess.com` for JWT validation; `api.cloudflare.com` and `update.argotunnel.com` only for update
  checks (off); DNS TXT `cfd-features.argotunnel.com`.
- Policies, in the `network-policy` component:

| Cluster | Policy |
| --- | --- |
| Talos, kind (Cilium) | `CiliumNetworkPolicy`: egress `toEntities: [world]` on 7844 TCP/UDP (`toFQDNs` needs the DNS proxy), 443 to the team domain, egress to the `ingress` identity; the [edge Gateway admission policy](0026-cloudflare-tunnel-edge-gateway.md#ingress-rules-and-the-edge-gateway), and `ingress` to backends |
| GKE (Dataplane V2) | Not offered, see [limits](#gke-and-kind-limits) |

## GKE and kind limits

- kind: not enabled, a dummy token only crash-loops `cloudflared`. A demo tunnel `dev-<user>` can be made by hand,
  outside the platform.
- GKE: not offered until the [GKE origin](../rfc/0026-cloudflare-tunnel.md#open-questions) question picks a Gateway implementation. The CCNP and `CiliumNetworkPolicy` CRDs exist on DPv2 and the same CCNP default deny ships ([RFC 0024](https://github.com/gsuquet/infra/pull/7), Default deny on GKE), but DPv2 has no L7 (CCNP is L3/L4 only), `toFQDNs` is unverified (`FQDNNetworkPolicy` instead), and there is no Cilium Gateway or `ingress` identity for the admission policy.

## Observability

Beyond the [signals in the RFC](../rfc/0026-cloudflare-tunnel.md#operational-impact):

- `cloudflared` metrics on 2000; connector health in the dashboard.
- Gateway and Hubble metrics for routed and denied flows.
- Access logs (Bypass is not logged).
