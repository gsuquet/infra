# Further arguments on the tunnel options

[RFC 0026](../rfc/0026-cloudflare-tunnel.md#options-considered) holds the main argument for and against each option; this page adds the others
and the sources.

## Remote-managed tunnel per cluster, owned by the cluster root

[Option in the RFC](../rfc/0026-cloudflare-tunnel.md#remote-managed-tunnel-per-cluster-owned-by-the-cluster-root). The tunnel uses
`config_src = "cloudflare"`, no secret.

- Good: tunnel and records live and die with the cluster state, so a CNAME never dangles (lifecycle).
- Good: the catch-all rule makes the ingress static per cluster (few moving parts).
- Bad: one person-run step per tunnel creation or rotation to move the token into the backend (no secret in state).
- Bad: the landing zone must know every cluster's platform hostnames (lifecycle).
- Bad: `cluster:up` of a new cluster needs a landing-zone apply first, since the `aud` lookup fails at plan
  (lifecycle).

## Landing zone creates every cluster's tunnel

[Option in the RFC](../rfc/0026-cloudflare-tunnel.md#landing-zone-creates-every-clusters-tunnel). One tunnel per cluster.

- Bad: the landing zone knows every cluster, and `cluster:up|down` needs a landing-zone apply (lifecycle).

## Tenant hostnames in a separate tenant root

[Option in the RFC](../rfc/0026-cloudflare-tunnel.md#tenant-hostnames-in-a-separate-tenant-root). The cluster root still owns the tunnel.

- Bad: adds a root outside the settled `landing-zone/`, `modules/`, `clusters/<name>/` layout (layout).
- Bad: needs the tunnel ID through `terraform_remote_state` or a lookup by name (lifecycle).

## One shared tunnel in the landing zone

[Option in the RFC](../rfc/0026-cloudflare-tunnel.md#one-shared-tunnel-in-the-landing-zone). DNS decides nothing, Cloudflare picks any connected
replica.

- Bad: every cluster must serve every hostname; during the olympus move traffic splits unpredictably (lifecycle).
- Bad: health is mixed across clusters in one tunnel.

## Locally-managed tunnel per cluster, ingress in Git

[Option in the RFC](../rfc/0026-cloudflare-tunnel.md#locally-managed-tunnel-per-cluster-ingress-in-git).

A credentials JSON plus a `config.yaml` ConfigMap rendered into Git.

- Bad: config visible only on the host, not in the dashboard.

## external-dns in the cluster for tenant hostnames

[Option in the RFC](../rfc/0026-cloudflare-tunnel.md#external-dns-in-the-cluster-for-tenant-hostnames).

- Bad: any tenant whose route attaches to the edge Gateway publishes a name; Access applications still need IaC.

## References

- [Terraform deployment guide (provider v5)](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/terraform/): reads the token with the data source, which the repo rule forbids
- [Create a tunnel with the API](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel-api/)
- [Useful terms](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/tunnel-useful-terms/)
- [Origin parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/origin-parameters/)
- Registry, provider 5.28.1: [`zero_trust_tunnel_cloudflared`](https://registry.terraform.io/providers/cloudflare/cloudflare/5.28.1/docs/resources/zero_trust_tunnel_cloudflared), [`zero_trust_tunnel_cloudflared_config`](https://registry.terraform.io/providers/cloudflare/cloudflare/5.28.1/docs/resources/zero_trust_tunnel_cloudflared_config), [`zero_trust_tunnel_cloudflared_token`](https://registry.terraform.io/providers/cloudflare/cloudflare/5.28.1/docs/data-sources/zero_trust_tunnel_cloudflared_token)
