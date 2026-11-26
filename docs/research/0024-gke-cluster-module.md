# GKE cluster module and landing zone

<!-- readability: allow-code R2 -->

Detail for [RFC 0024](../rfc/0024-gke.md); check date, sources and **(unverified)** marks: see its
[Context](../rfc/0024-gke.md#context).

## Cluster settings

`modules/cluster-gke` sets:

| Setting | Value | Why |
|---|---|---|
| Mode, location | Standard, one zone | Free tier credit covers zonal or Autopilot only; a regional Standard cluster never is |
| `datapath_provider` | `ADVANCED_DATAPATH` | DPv2; **creation-only**: "Existing clusters cannot be upgraded" |
| `enable_cilium_clusterwide_network_policy` | `true` | CCNP for the `network-policy` component (GA field) |
| `enable_fqdn_network_policy` | `true` | GKE `FQDNNetworkPolicy` for egress by name |
| `gateway_api_config.channel` | `CHANNEL_STANDARD` | GKE owns the Gateway API CRDs on GKE (ADR-0012) |
| `workload_identity_config.workload_pool` | `<project>.svc.id.goog` | Workload Identity, optional on Standard, enabled anyway |
| `control_plane_endpoints_config` | `dns_endpoint_config { allow_external_traffic = true }`, `ip_endpoints_config { enabled = false }` | IAM-gated endpoint, no bastion |
| `private_cluster_config.enable_private_nodes` | `var.private_nodes` (default `true`) | Nodes without public IPs; egress through Cloud NAT. `false` gives public nodes without NAT behind GKE firewall rules ([open question](../rfc/0024-gke.md#open-questions)) |
| `dns_config.cluster_dns` | `KUBE_DNS` | kube-dns allow of the default deny keeps matching |
| `advanced_datapath_observability_config` | `enable_relay = true`, `enable_metrics = var.observability_metrics` (default `false`) | Managed Hubble relay; metrics bill in Managed Prometheus |
| `logging_config.enable_components` | `["SYSTEM_COMPONENTS"]` | Limit Cloud Logging ingestion |
| Default node pool | omitted (`initial_node_count` unset) | Needs GKE `1.36.4-gke.1469000`+, so `min_master_version` is pinned at or above it |
| `release_channel`, `maintenance_policy`, `deletion_protection` | `REGULAR`, set, `true` | `cluster:down` applies `deletion_protection = false` first |

Default node pool fallback: if the zone or channel cannot offer `1.36.4-gke.1469000` yet, use
`remove_default_node_pool = true` plus `initial_node_count = 1` (deprecated field), removed once the version is
available.

## Inputs and outputs

```hcl
variable "name"                  { type = string }
variable "project_id"            { type = string }
variable "location"              { type = string }  # a zone: keeps the free tier credit
variable "network"               { type = string }  # from landing-zone/gcp
variable "subnet_cidr"           { type = string }
variable "pods_cidr"             { type = string }
variable "services_cidr"         { type = string }
variable "release_channel"       { type = string, default = "REGULAR" }
variable "min_master_version"    { type = string }  # >= 1.36.4-gke.1469000
variable "deletion_protection"   { type = bool, default = true }
variable "extra_webhook_ports"   { type = list(number), default = [] } # webhooks not on 443/10250
variable "observability_metrics" { type = bool, default = false }
variable "private_nodes"         { type = bool, default = true }  # needs the landing zone's Cloud NAT

variable "node_pools" {
  type = map(object({
    machine_type = string
    spot         = bool
    min          = number           # autoscaling bounds
    max          = number
    disk_gb      = optional(number, 50)
    labels       = optional(map(string), {})
    taints       = optional(list(object({ key = string, value = string, effect = string })), [])
  }))
  validation {
    condition     = length(var.node_pools) > 0
    error_message = "At least one node pool."
  }
}

# outputs: cluster name, location, dns_endpoint, workload_pool, control plane CIDR,
#          platform_placement (nodeSelector + tolerations, empty unless pools are mixed)
```

Resources: `google_compute_subnetwork` (subnet and secondary ranges), `google_container_cluster`, one
`google_container_node_pool` per `node_pools` entry with autoscaling, and `google_compute_firewall` only when
`extra_webhook_ports` is not empty. No CA output: the DNS endpoint certificate "is signed by a public, generally
recognized Google CA", so `clusters/<name>/` sets the `kubernetes` and `helm` providers with
`host = "https://${dns_endpoint}"` and a `google_client_config` token, without `cluster_ca_certificate`.

## Control plane and nodes

- Laptop: `gcloud container clusters get-credentials <name> --location <location> --dns-endpoint` (untested,
  flag spelling **(unverified)**), with the user's IAM role on the project.
- CI needs no cluster access while `plan` stays local (ADR-0019). Later: GitHub OIDC through a WIF pool in
  `landing-zone/gcp`, granting a read-only Kubernetes role.
- Private Standard nodes accept control plane to Pod traffic only on 443 and 10250. cert-manager
  (`webhook.securePort: 10250`, chart comment cites GKE private clusters) and ESO (`webhook.port: 10250`) already
  default to 10250, so no firewall rule while every catalog webhook listens on 443 or 10250.
- Cloud NAT carries node egress: cloudflared, and image pulls from non-Google registries.

## Landing zone

`landing-zone/gcp` uses the R2 backend, key `landing-zone/gcp/terraform.tfstate`.

Key named like `landing-zone/cloudflare/terraform.tfstate` and ADR-0018's `clusters/<name>/terraform.tfstate`;
RFC 0022 reads existing state unchanged and renames no key.

| Resource | Content |
|---|---|
| `google_project` (or an import) | Linked to the billing account |
| `google_project_service` | `container`, `compute`, `iam`, `iamcredentials`, `sts`, `cloudresourcemanager`, `serviceusage`, `billingbudgets`, `logging`, `monitoring`; `secretmanager` and `artifactregistry` only if chosen |
| `google_billing_budget` | Thresholds such as 50/90/100% of a monthly amount; alerts, does not cap spend **(cap behaviour unverified)**; billing admins or Monitoring notification channels |
| `google_compute_network` | One VPC, custom subnets; per-cluster subnets and ranges belong to `cluster-gke` |
| `google_compute_router`, `google_compute_router_nat` | Only if private nodes are chosen ([open question](../rfc/0024-gke.md#open-questions)) |
| `google_iam_workload_identity_pool` and provider | GitHub OIDC with an `attribute_condition` on the immutable `assertion.repository_owner_id` and `assertion.repository_id`, never on renamable names ([GitHub OIDC](https://docs.github.com/en/actions/reference/security/oidc)); deferred until CI needs Google Cloud |

No secret value in state, same rule as `landing-zone/cloudflare`. Artifact Registry is not created: platform
images come from upstream, tenant images from GHCR; add a remote or cache repository if Docker Hub rate limits bite.

## Raw provider resources over `terraform-google-modules`

| | `hashicorp/google` resources (chosen) | `terraform-google-modules/kubernetes-engine/google` |
|---|---|---|
| Version on 2026-11-17 | 8.12.0 | 47.0.0 (2026-10-30) |
| Surface | About 20 fields we set | 146 root inputs, 20+ submodules |
| Provider | GA `google`: every field above is GA | Submodules enable beta features, so `google-beta` |
| Upgrade churn | Renovate bumps one provider | 47 majors so far |

Versions were read on registry.terraform.io; with OpenTofu (RFC 0022) the provider resolves from
registry.opentofu.org, which carries the same `google` binaries, and the lock file records that address.
`project-factory` (18.4.0) and `network` (18.3.1) are not worth it at one project and one VPC either. Same
pattern as `modules/cloudflare-domain`.

## Sources

- [Network isolation](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/network-isolation)
