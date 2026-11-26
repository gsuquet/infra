# GKE future work

Detail for [RFC 0024](../rfc/0024-gke.md); check date, sources and **(unverified)** marks: see its
[Context](../rfc/0024-gke.md#context).

## Future work

- `gateway-api-crds` as the CRD owner on GKE Standard (`CHANNEL_DISABLED`, Experimental types possible): needs an
  RFC that supersedes the GKE part of ADR-0012.
- `ClusterNetworkPolicy` Baseline-tier default deny, once GA on GKE and implemented by upstream Cilium.
- Cloud DNS for GKE, with `toCIDR` DNS allows.
- GitHub OIDC WIF pool and a read-only Kubernetes role for CI.
- Artifact Registry remote or cache repository if Docker Hub rate limits bite.
- A descheduler to move tenant pods back to Spot.
- OpenTofu ownership of the Cloudflare DNS-01 token through a write-only or ephemeral attribute.

## Related ADRs

- ADR-0003, ADR-0008, ADR-0010, ADR-0011, ADR-0012, ADR-0013, ADR-0014, ADR-0015, ADR-0017, ADR-0018, ADR-0019
