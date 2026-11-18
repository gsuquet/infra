# GKE as the first cloud target

Status: study, nothing implemented. Sources checked on 2026-11-18 against `cloud.google.com`,
`docs.cloud.google.com`, `registry.terraform.io` (google provider 8.12.0 docs), `cert-manager.io`,
`external-secrets.io`, `docs.cilium.io`, `docs.github.com` and the cert-manager and ESO chart `values.yaml` on
`raw.githubusercontent.com`. Anything marked **(unverified)** was not confirmed on those pages.

## TL;DR

- **Recommend GKE Standard, zonal, Dataplane V2.** The cluster management fee is covered by the free tier credit
  for one zonal or Autopilot cluster. Node cost of Standard vs Autopilot is not compared here: Standard node prices
  could not be read **(unverified)**. Autopilot breaks two platform invariants: GKE owns the Gateway API CRDs (GKE
  Gateway "is always enabled on Autopilot clusters"), and privileged pods run only for allowlisted partners, which
  rules out Falco and Tetragon.
- **Node pools:** Spot keeps the bill low but can leave the cluster with zero nodes (preemption, stockout), Argo CD
  included. Choose between a small on-demand pool for the baseline plus Spot for tenants, or Spot only with outages
  accepted (open question 9).
- **Dataplane V2 covers what the plan needs from Cilium** (eBPF datapath, no kube-proxy, `CiliumClusterwideNetworkPolicy`,
  managed Hubble relay), with three differences: CCNP is L3/L4 only, FQDN egress uses a GKE CRD
  (`FQDNNetworkPolicy`) rather than Cilium `toFQDNs`, and **Google does not support custom eBPF programs on DPv2
  nodes**. Tetragon and eBPF-mode Falco may still run on Standard, at our own risk of interfering with `anetd`.
- **Default-deny on GKE needs two more baseline allows:** egress to the GKE metadata server (Workload Identity) and,
  if Cloud DNS is ever used, to its node-local resolver. `cluster-gke` pins `cluster_dns = "KUBE_DNS"`.
- **Gateway API:** on Standard, set `gateway_api_config.channel = "CHANNEL_DISABLED"` so our `gateway-api-crds`
  component stays the single CRD owner. Public traffic goes through Cloudflare Tunnel, so the GKE Gateway controller
  (Google Cloud load balancers) is not needed.
- **Control plane:** DNS-based endpoint only, IP endpoints disabled. Laptop and CI reach it with IAM, without a
  bastion or authorized networks.
- **Workload Identity is barely needed today.** DNS lives on Cloudflare, so cert-manager DNS-01 uses a Cloudflare
  token, not Cloud DNS. Workload Identity matters only if the secrets study picks Google Secret Manager.
- **Terraform:** raw `google_container_cluster` and `google_container_node_pool` in `modules/cluster-gke`, not
  `terraform-google-modules/kubernetes-engine` (v47.0.0, 146 root inputs, google-beta, 47 major versions).

## 1. Autopilot vs Standard

### Cost floor

From the [GKE pricing page](https://cloud.google.com/kubernetes-engine/pricing):

- Cluster management fee: **US$0.10/hour per cluster**, flat whatever the mode (about $73/month).
- Free tier: "**$74.40 in monthly credits per billing account**, which is equivalent to one free Autopilot or zonal
  Standard cluster per month. Free tier credits are only applied to zonal and Autopilot clusters". A regional
  Standard cluster is never covered. A second cluster on the same billing account pays the full fee.
- Autopilot general-purpose Pods are billed per second on the **requests** (CPU, memory, ephemeral storage), with
  no minimum duration. Iowa (us-central1) list prices:

  | SKU | On demand | Spot |
  |---|---|---|
  | vCPU-hour | $0.0445 | $0.0133 |
  | GiB-hour of memory | $0.0049225 | $0.0014767 |

- Standard is billed per Compute Engine node (per second, one-minute minimum). Node prices were not readable from
  the pricing page (rendered client-side) **(unverified)**. Use the pricing calculator before choosing a machine type.

Rough Autopilot estimate for the baseline set (argocd, cert-manager, external-secrets, a Gateway implementation,
cloudflared). Assume about 1.25 vCPU and 3 GiB of requests in total **(estimate, measure on kind first)**:

| | vCPU | Memory | Total per month (730 h) |
|---|---|---|---|
| On demand | 1.25 × 0.0445 × 730 ≈ $40.6 | 3 × 0.0049225 × 730 ≈ $10.8 | **≈ $51** |
| Spot | 1.25 × 0.0133 × 730 ≈ $12.1 | 3 × 0.0014767 × 730 ≈ $3.2 | **≈ $15** |

Standard pays for whole nodes. The baseline should fit one 2 vCPU / 8 GiB node **(unverified sizing)**, but its
Spot and on-demand prices, boot disk and Cloud NAT figures were not readable here, so **no Standard vs Autopilot
cost claim is made**. Get them from the pricing calculator before open question 1. Both modes pay extra for:

- persistent disks (and node boot disks on Standard);
- egress traffic;
- Cloud NAT when nodes are private: a gateway charge plus per-GB processing **(unverified figures)**;
- external IPv4 addresses on public nodes **(unverified figures)**;
- Dataplane V2 observability metrics (`enable_metrics`), ingested into Managed Service for Prometheus, which bills
  per sample **(billing basis unverified)**. The module leaves them off until needed;
- Cloud Logging and Cloud Monitoring ingestion for system components, above the free allotment
  **(free allotment unverified)**. Keep `logging_config` to `SYSTEM_COMPONENTS` and watch the budget.

Spot risk: a Spot VM can be preempted at any time with short notice, and during a stockout there is no Spot capacity
at all **(notice length and stockout behaviour from Compute Engine docs, not re-read here)**. With a single Spot pool,
the cluster can sit at zero nodes, and Argo CD with it, so nothing self-heals until capacity returns. Options:

- a small on-demand pool (1 node) for the baseline components, tainted or labelled, plus an autoscaled Spot pool
  (min 0) for tenants;
- Spot only, with outages explicitly accepted for a personal platform.

Cloudflare Tunnel removes the need for any Google Cloud load balancer, and so its forwarding-rule cost.

Autopilot traps for tenants ([resource requests](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/autopilot-resource-requests)):

- A container without requests defaults to **0.5 vCPU / 2 GiB**.
- The minimum is 50m CPU / 52 MiB on clusters that support bursting, otherwise 250m / 512 MiB.
- CPU:memory must stay between 1:1 and 1:6.5, and Autopilot raises the smaller resource to fit.

The tenant LimitRange must set default requests, or every unannotated Pod costs 0.5 vCPU.

### What Autopilot forbids that this plan needs

From [Autopilot security measures](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/autopilot-security)
and [partner workloads](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/run-autopilot-partner-workloads):

| Need | Autopilot | Impact |
|---|---|---|
| Own Cilium DaemonSet | Not applicable: Dataplane V2 is the Cilium | None, the catalog already skips cilium on GKE |
| Privileged pods (Falco, Tetragon) | "Containers can't run in Privileged mode unless the container is deployed by a Google Cloud partner." Neither Falco, Tetragon nor Cilium is on the [partner allowlist](https://docs.cloud.google.com/kubernetes-engine/docs/resources/autopilot-partners). Running your own privileged workloads is "available only to eligible Google Cloud customers". | Only allowlisted partner sensors (commercial runtime security products) can run; Falco and Tetragon cannot |
| hostPath | Read-only `/var/log` only; "denies all other read or write access" | Log shippers that tail node files: read-only works |
| Host namespaces | "Autopilot blocks host namespaces." | No hostNetwork components |
| NET_ADMIN | Dropped; can be re-enabled per cluster (`allow_net_admin`, `--workload-policies=allow-net-admin`) | Only matters for mesh sidecar init |
| Workloads in `kube-system` | "Autopilot doesn't allow deploying workloads in GKE-managed namespaces" | cert-manager must not use `kube-system` for leader election ([cert-manager compatibility](https://cert-manager.io/docs/installation/compatibility/): set `global.leaderElection.namespace=cert-manager`) |
| Webhooks | Allowed. GKE rewrites them to exclude managed namespaces, and rejects webhooks on nodes, persistentvolumes, certificatesigningrequests and tokenreviews | Fine for cert-manager, ESO, Kyverno-style admission |
| CRDs | Not restricted on the pages read | Fine |
| DaemonSets (unprivileged) | Allowed, with their own minimums (1m CPU / 2 MiB on bursting clusters) | Fine |
| Gateway API CRDs | GKE Gateway "is always enabled", and Experimental channel CRDs cannot be installed | **Conflicts with `gateway-api-crds` owning the CRDs** |
| Node SSH | Blocked | Fine |

### Recommendation

Use **Standard, zonal, `datapath_provider = "ADVANCED_DATAPATH"`**, with node pools per open question 9 (default
proposal: one on-demand node for the baseline, an autoscaled Spot pool for tenants).

- It keeps the same invariants as kind and Talos: `gateway-api-crds` owns the CRDs, and Experimental channel types
  stay possible.
- The fee is free under the credit.
- A zonal control plane has a 99.5% SLA (99.95% for regional and Autopilot), which is fine for this platform.

Autopilot stays an option if the owner accepts the following. Do not support both modes in `cluster-gke` up front:
that is scope creep until a second GKE cluster exists.

- `gateway-api-crds` is skipped on Autopilot clusters, and GKE owns the CRD version.
- No privileged opt-in components.

## 2. Dataplane V2 vs our Cilium needs

From [Dataplane V2](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2):

| Need | DPv2 | Notes |
|---|---|---|
| eBPF datapath, kube-proxy replacement | Yes: "uses `cilium` instead of `kube-proxy` to implement Kubernetes Services" | **Only at cluster creation**: "Existing clusters cannot be upgraded". The module must set it from day one. |
| `CiliumClusterwideNetworkPolicy` | Yes, opt-in: `enable_cilium_clusterwide_network_policy = true` (GA field in the `google` provider). Needs gcloud 465.0.0+ for the CLI path. [Doc](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/configure-cilium-network-policy) | "Layer 7 policies are not supported", "Node selectors are not supported", maximum 1000 CCNP per cluster. GKE calls CCNP "a proprietary API" and steers new work to `ClusterNetworkPolicy`. |
| `CiliumNetworkPolicy` (namespaced) | CRD present on DPv2 clusters (the doc mentions scale limits for clusters "using the CiliumNetworkPolicy CRD") | Tenants are already denied it through the AppProject |
| FQDN egress | GKE `FQDNNetworkPolicy` (`networking.gke.io/v1alpha1`), `enable_fqdn_network_policy = true`. [Doc](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/fqdn-network-policies) | Not Cilium `toFQDNs`: whether CCNP `toFQDNs` works on GKE is **(unverified)**, assume not. Limits: 50 IPs per policy, single-level wildcards, kube-dns or Cloud DNS only. On an existing Standard cluster, enabling it needs an `anetd` restart. |
| Hubble | Managed: `monitoring_config.advanced_datapath_observability_config { enable_metrics, enable_relay }`. Hubble relay and CLI are provided, Hubble UI is an optional deploy. [Doc](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/about-dpv2-observability) | Metrics go to Managed Service for Prometheus. No Hubble component of ours on GKE. |
| Policy logging | Built in, configured through a logging CRD | Replaces Hubble-based deny auditing |
| Cilium Gateway API / Envoy L7 | Not offered by DPv2 **(unverified, no page says so; the CCNP doc rejects L7)** | GKE needs a non-Cilium Gateway implementation |
| Custom eBPF programs | "GKE doesn't support installing custom eBPF programs on nodes that use GKE Dataplane V2." Reason given: they "can interfere with GKE Dataplane V2 programs and might disrupt cluster networking", and GKE raises a Recommendation when it detects one. | A support statement, not a technical block. Falco and Tetragon attach tracing programs, not datapath programs, so they may run on Standard, but at our own risk of interfering with `anetd` and without Google support. Owner decision (open question 6). |

Running our own Cilium on Standard *instead of* DPv2 is possible per the
[Cilium GKE install](https://docs.cilium.io/en/stable/installation/k8s-install-helm/) (`gke.enabled`, NodeInit
DaemonSet, node taint `node.cilium.io/agent-not-ready`). It would mean a legacy-datapath cluster, a privileged
NodeInit that rewrites kubelet, and no Google support for the CNI. Not recommended: DPv2 is the managed equivalent
the plan already chose.

### Default-deny on GKE

The cluster-layer CCNP (default-deny on namespaces with the policy label, allows for kube-dns and the API server)
carries over, with these constraints:

1. **Express default-deny with allow-only rules, never `ingressDeny`/`egressDeny`.** On GKE, "explicit Deny rules
   in a CCNP override allow rules in namespace-scoped policies". An explicit deny would also block tenant
   NetworkPolicies. Selecting an endpoint with allow rules already puts it in default-deny, which is also how
   upstream Cilium behaves.
2. Selecting by namespace label through `endpointSelector` (`k8s:io.cilium.k8s.namespace.labels.<key>`) and
   `toEntities: [kube-apiserver]` were not confirmed by the GKE doc. Its examples only use `endpointSelector`,
   `fromEndpoints`, `toPorts` and `toCIDR` **(unverified, test on the first GKE cluster)**. If `toEntities` is
   rejected, the allow for the API server falls back to `toCIDR` with the control plane address, an output of
   `cluster-gke`.
3. **GKE metadata server.** The [Workload Identity doc](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/workload-identity)
   says that with a strict network policy you must "allow egress to 169.254.169.252/32 on port 988" and, "for
   clusters running GKE Dataplane V2", to "169.254.169.254/32 on port 80". Without it, ESO on Google Secret Manager
   and anything else using Workload Identity or the metadata server fails. The GKE variant of the cluster-layer CCNP
   adds a third baseline allow with `toCIDR` for both addresses and ports, on every labelled namespace (simpler than
   tracking which namespaces use Workload Identity; the metadata server only serves the Pod's own identity).
4. **Cluster DNS.** The kube-dns allow selects kube-dns Pods. With Cloud DNS for GKE (default on new Autopilot
   clusters since 1.25.9-gke.400, opt-in on Standard), Pods resolve through 169.254.169.254:53 on Standard or
   NodeLocal DNSCache 169.254.20.10 on Autopilot ([Cloud DNS doc](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cloud-dns)),
   so the pod selector no longer matches. `cluster-gke` pins `dns_config { cluster_dns = "KUBE_DNS" }` so the
   baseline stays identical to kind and Talos. If Cloud DNS is ever chosen, the baseline needs `toCIDR` allows on
   port 53 for those addresses instead.
5. GKE-managed namespaces (`kube-system`, `gke-managed-*`, `gmp-system`…, list **(unverified)**) carry no policy
   label, so the label-driven selector already leaves them out. Conftest only checks rendered namespaces, so
   nothing changes there.
6. `ClusterNetworkPolicy` (`policy.networking.k8s.io/v1alpha2`, Admin and Baseline tiers, GKE 1.36.0-gke.4447000+)
   is the cleaner primitive: Baseline tier default-deny that tenants override. It is Pre-GA on GKE and alpha
   upstream. Revisit when Cilium upstream implements it, so that kind and Talos can share it **(Cilium support
   unverified)**.

## 3. Gateway API on GKE

- `gateway_api_config.channel` accepts `CHANNEL_DISABLED`, `CHANNEL_STANDARD` or `CHANNEL_EXPERIMENTAL` (provider
  docs). With `--gateway-api=standard`, "GKE [installs] the CRDs of the Gateway API Standard Channel with the
  cluster". Reconciliation can take up to 45 minutes.
- The GKE Gateway controller provisions Google Cloud load balancers (`gke-l7-global-external-managed`,
  `gke-l7-regional-external-managed`, `gke-l7-gxlb`, `gke-l7-rilb`). "You can use multiple Gateway controllers,
  including controllers not provided by Google, in a GKE cluster simultaneously."
- No page states what GKE does with Gateway API CRDs it did not install, or whether disabling the channel removes
  CRDs that GKE installed **(unverified)**.

Options:

| | A. GKE owns the CRDs | B. `gateway-api-crds` owns the CRDs (recommended, Standard only) |
|---|---|---|
| Setting | `CHANNEL_STANDARD` | `CHANNEL_DISABLED` from cluster creation |
| Catalog | Skip `gateway-api-crds` on GKE; the implementation must match the version GKE ships | Same as kind and Talos |
| GKE load balancer classes | Available | Not available (not needed with Cloudflare Tunnel) |
| Experimental types (TLSRoute…) | No on Autopilot | Yes, if the component ships them |
| Bootstrap | Terraform skips `bootstrap-gateway-api` | Terraform runs `bootstrap-gateway-api` as on kind and Talos |

Autopilot forces A. Option B must be checked on the first cluster: confirm that no `gateway.networking.k8s.io`
CRD exists before the bootstrap.

The Gateway implementation on GKE is any non-Cilium one installed without bundled CRDs, with its own
GatewayClass. Envoy Gateway is one example **(choice belongs to the Gateway study)**. Its Service stays ClusterIP,
and cloudflared targets it.

## 4. Workload Identity Federation for GKE

- It is always enabled on Autopilot and optional on Standard: `workload_identity_config.workload_pool = "<project>.svc.id.goog"`.
  The module enables it in both modes.
- Direct principals work without a Google service account:
  `principal://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/PROJECT_ID.svc.id.goog/subject/ns/NAMESPACE/sa/KSA`.
  Some APIs still need impersonation ([doc](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/workload-identity)).
- **Identity sameness:** every cluster in a project shares the pool. The same namespace and service account in two
  clusters get the same access, which matters for tenant namespaces.
- `hostNetwork: true` Pods do not get Workload Identity.

Per consumer:

- **cert-manager DNS-01: no Workload Identity.** The zones are on Cloudflare: the ClusterIssuer uses
  `dns01.cloudflare.apiTokenSecretRef`. The token needs "Zone - DNS - Edit" and "Zone - Zone - Read"
  ([cert-manager](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)). ESO delivers it from the
  `secrets` store. **The token is created by hand in the Cloudflare dashboard**, scoped to those two permissions on
  the platform zones, and stored only in the secrets backend. It is not a `cloudflare_api_token` resource in
  `landing-zone/cloudflare`: its value would land in state, which breaks that root's rule "No secret value is
  created by a resource of this configuration". Terraform ownership waits for a write-only or ephemeral token
  attribute (open question 10, for the secrets study). Cloud DNS plus Workload Identity applies only if a zone ever
  moves to Google Cloud.
- **ESO: Workload Identity only if the backend is Google Secret Manager** (open study). The
  [ESO provider](https://external-secrets.io/latest/provider/google-secrets-manager/) supports three patterns:
  - `auth.workloadIdentity.serviceAccountRef` with the service account as a direct principal holding
    `roles/secretmanager.secretAccessor`;
  - a service account linked through the `iam.gke.io/gcp-service-account` annotation;
  - the controller's own identity (`gcpsm: {}`).

  To keep "every namespace has a store named `secrets`", use a per-namespace `SecretStore` with
  `serviceAccountRef` set to a service account in that namespace. Grant IAM per secret, or per secret prefix
  through IAM conditions **(conditions on Secret Manager unverified)**, so a tenant cannot read another tenant's
  secrets.

## 5. Control plane access

From [network isolation](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/network-isolation) and the
provider docs:

- **DNS-based endpoint (recommended):** "accessible from any network reachable by Google Cloud APIs" and gated by
  IAM. It "eliminates the need for a bastion host or proxy nodes". Terraform:
  `control_plane_endpoints_config { dns_endpoint_config { allow_external_traffic = true } ip_endpoints_config { enabled = false } }`.
- Laptop: `gcloud container clusters get-credentials <name> --location <loc> --dns-endpoint`
  **(flag spelling unverified)**, with the user's IAM role on the project.
- Terraform `helm`/`kubernetes` providers in `clusters/<name>/` use the DNS endpoint output and a
  `google_client_config` access token.
- CI: it needs no cluster access while `terraform plan` stays local. Later, GitHub OIDC through a WIF pool in
  `landing-zone/gcp` grants a read-only Kubernetes role.
- **Nodes:** private nodes need Cloud NAT for egress (cloudflared, image pulls from non-Google registries). Public
  nodes avoid NAT but expose node IPs, with GKE firewall rules in front.
  - Recommendation: private nodes and Cloud NAT. Accept the cost after checking it in the calculator.
  - Private Standard nodes block control plane → Pod traffic except on ports 443 and 10250. cert-manager's
    [compatibility page](https://cert-manager.io/docs/installation/compatibility/) warns that the webhook fails
    without a firewall rule, but both charts already default their webhook to 10250 for this reason: cert-manager
    `webhook.securePort: 10250` ("In GKE private clusters, by default Kubernetes apiservers are allowed to talk to
    the cluster nodes only on 443 and 10250", chart `values.yaml`) and ESO `webhook.port: 10250`. **No extra
    firewall rule is needed while every catalog webhook listens on 443 or 10250.** The catalog keeps those ports;
    `cluster-gke` gets an optional `extra_webhook_ports` list (empty by default) that creates a
    `google_compute_firewall` only for a component that cannot move.

## 6. Terraform

### google provider vs terraform-google-modules

| | `hashicorp/google` resources | `terraform-google-modules/kubernetes-engine/google` |
|---|---|---|
| Version on the registry | 8.12.0 (2026-11-17) | 47.0.0 (2026-10-30) |
| Surface | The fields we set (around 20) | 146 root inputs, 20+ submodules (`gke-standard-cluster`, `gke-autopilot-cluster`, `private-cluster`, `safer-cluster`, `workload-identity`…) |
| Provider | GA `google`: every field we need is GA in the docs (`enable_cilium_clusterwide_network_policy`, `enable_fqdn_network_policy`, `gateway_api_config`, `control_plane_endpoints_config`, `advanced_datapath_observability_config`) | Submodules state "Beta features are enabled", which brings google-beta |
| Upgrade churn | Renovate bumps one provider | 47 majors so far; each major means reading a changelog for inputs we do not use |

**Use raw resources**, as `landing-zone/cloudflare/modules/domain` already does with the Cloudflare provider.
`terraform-google-modules/project-factory` (18.4.0) and `network` (18.3.1) are not worth it either at one project
and one VPC.

### `landing-zone/gcp/` (root module, R2 backend, key `landing-zone/gcp/terraform.tfstate`)

Foundation that outlives clusters:

- `google_project` (or import of an existing one) linked to the billing account. Project per environment vs a
  single project: see open questions.
- `google_project_service` for:
  - `container`, `compute`, `iam`, `iamcredentials`, `sts`, `cloudresourcemanager`, `serviceusage`,
    `billingbudgets`, `logging`, `monitoring`;
  - `secretmanager` only if chosen;
  - `artifactregistry` only if chosen.
- `google_billing_budget`, with thresholds such as 50/90/100% of a monthly amount. A budget alerts, it does not cap
  spend **(cap behavior unverified)**. Alerts go to billing admins, or to Monitoring notification channels for
  custom emails.
- Network: one VPC (`google_compute_network`, custom subnets). If private nodes are chosen, add
  `google_compute_router` and `google_compute_router_nat`. Subnets and secondary ranges per cluster belong to
  `cluster-gke`, so a cluster root creates and destroys its own ranges.
- `google_iam_workload_identity_pool` and `google_iam_workload_identity_pool_provider` for GitHub OIDC, with an
  `attribute_condition` on the immutable numeric claims `assertion.repository_owner_id` and `assertion.repository_id`
  ([GitHub OIDC claims](https://docs.github.com/en/actions/reference/security/oidc)), not on the owner or repository
  names, which can be renamed and re-registered. Defer until CI needs Google Cloud.
- Artifact Registry (`google_artifact_registry_repository`): **not now.** Platform images come from upstream
  registries and tenant images can use GHCR. Add a remote or cache repository later if Docker Hub rate limits bite.

No secret value in state, same rule as `landing-zone/cloudflare`.

### `modules/cluster-gke/` shape

```hcl
# variables (sketch)
variable "name"               { type = string }
variable "project_id"         { type = string }
variable "location"           { type = string }            # a zone: keeps the free tier credit
variable "network"            { type = string }            # from landing-zone/gcp
variable "subnet_cidr"        { type = string }
variable "pods_cidr"          { type = string }
variable "services_cidr"      { type = string }
variable "release_channel"    { type = string, default = "REGULAR" }
variable "node_pool"          { type = object({ machine_type = string, spot = bool, min = number, max = number, disk_gb = number }) }
variable "gateway_api_channel"{ type = string, default = "CHANNEL_DISABLED" } # gateway-api-crds owns the CRDs
variable "deletion_protection"{ type = bool, default = true }
variable "min_master_version" { type = string }             # pinned, >= 1.36.4-gke.1469000 (see below)
variable "extra_webhook_ports"{ type = list(number), default = [] } # webhooks not on 443/10250
variable "observability_metrics" { type = bool, default = false } # DPv2 metrics, billed in Managed Prometheus

# resources
# google_compute_subnetwork          subnet + secondary ranges (pods, services)
# google_container_cluster           datapath_provider = "ADVANCED_DATAPATH"   (creation-only)
#                                    enable_cilium_clusterwide_network_policy = true
#                                    enable_fqdn_network_policy = true
#                                    gateway_api_config { channel = var.gateway_api_channel }
#                                    workload_identity_config { workload_pool = "${var.project_id}.svc.id.goog" }
#                                    control_plane_endpoints_config { dns_endpoint_config { allow_external_traffic = true }
#                                                                     ip_endpoints_config { enabled = false } }
#                                    private_cluster_config { enable_private_nodes = true }
#                                    dns_config { cluster_dns = "KUBE_DNS" }   (baseline kube-dns allow keeps matching)
#                                    monitoring_config { advanced_datapath_observability_config {
#                                      enable_metrics = var.observability_metrics, enable_relay = true } }
#                                    logging_config { enable_components = ["SYSTEM_COMPONENTS"] }
#                                    release_channel, min_master_version, maintenance_policy, deletion_protection
#                                    no default node pool (initial_node_count omitted, GKE 1.36.4-gke.1469000+)
# google_container_node_pool         one per entry (baseline on-demand / tenants Spot, open question 9) + autoscaling
# google_compute_firewall            count = length(var.extra_webhook_ports) > 0 ? 1 : 0

# outputs: cluster name, location, dns_endpoint, workload_pool, control-plane CIDR
```

Default node pool: the provider docs say omitting `initial_node_count` skips the default pool only on GKE
`1.36.4-gke.1469000+`; older versions need `remove_default_node_pool = true` plus `initial_node_count = 1`, and
`remove_default_node_pool` is marked deprecated. The module therefore pins `min_master_version` at or above that
version instead of trusting the REGULAR channel default. If the chosen zone or channel cannot offer it yet, the
documented fallback is `remove_default_node_pool = true` + `initial_node_count = 1`, removed once the version is
available.

The DNS endpoint's certificate "is signed by a public, generally recognized Google CA" (network isolation doc),
unlike the IP endpoint which uses the cluster root CA. So the `kubernetes`/`helm` providers in `clusters/<name>/`
use `host = "https://${dns_endpoint}"` and a `google_client_config` token, with no `cluster_ca_certificate`; the
module does not output the CA.

`clusters/<name>/` composes `cluster-gke`, then `bootstrap-gateway-api` (option B only) and `bootstrap-argocd`.
There is no `bootstrap-cilium` on GKE. `mise run cluster:down <name>` needs `deletion_protection = false` applied
first, because the provider defaults it to true.

## 7. Catalog adjustments for GKE

`cluster.yaml` gains a `provider: gke` (or `kind`/`talos`) that the renderer uses for provider defaults:

| Component | GKE treatment |
|---|---|
| `cilium` | Skipped (already planned). DPv2 instead. |
| `gateway-api-crds` | Kept on Standard with `CHANNEL_DISABLED`; skipped if Autopilot or `CHANNEL_STANDARD` is ever chosen |
| Gateway implementation | Non-Cilium implementation, no bundled CRDs, own GatewayClass, ClusterIP Service behind cloudflared |
| `argocd` | Unchanged |
| `cert-manager` | Set `global.leaderElection.namespace=cert-manager` in the default values for every provider (harmless elsewhere, required on Autopilot). Cloudflare DNS-01 issuer, token from the `secrets` store. |
| `external-secrets` | `secrets` store backend per provider: in-cluster dummy store on kind, backend from the secrets study elsewhere. Workload Identity wiring only for Google Secret Manager. |
| `cloudflared` | Unchanged (outbound only; needs NAT with private nodes) |
| Hubble / hubble-ui | No relay component (GKE-managed). Optional `hubble-ui` pointed at the GKE relay (service name **unverified**). |
| Network policy (cluster layer) | Same CCNP, allow-only form, no node selectors, no L7, plus the metadata server allow (169.254.169.254/32:80, 169.254.169.252/32:988). API server allow may need `toCIDR` (see §2). |
| Tenant AppProject | Also add `FQDNNetworkPolicy` (`networking.gke.io`) to `namespaceResourceBlacklist` on GKE, otherwise tenants can widen egress |
| Falco / Tetragon | Owner decision (open question 6). Impossible on Autopilot (privileged, not on the partner allowlist). On Standard, possible but unsupported by Google on DPv2 nodes, at our own risk of interfering with `anetd`. Until decided, the catalog does not enable them on GKE. |
| kubeconform | Needs schemas for GKE CRDs (`FQDNNetworkPolicy`, `ClusterNetworkPolicy` if used) |

## Open questions for the owner

1. **Standard zonal (recommended) or Autopilot?** Autopilot means GKE owns the Gateway API CRDs on that cluster and
   rules out privileged components. Standard means managing a node pool.
2. **Region/zone:** europe-west1 (Belgium), europe-west9 (Paris) or us-central1 (cheapest list prices)? Prices
   differ by region and the free tier credit is region-agnostic.
3. **Private nodes plus Cloud NAT, or public nodes** to save the NAT cost? Check the figures in the pricing
   calculator first.
4. **One project per cluster or a shared project?** Workload Identity pools are per project. Tenant namespaces with
   the same name on two clusters share IAM identity in a shared project.
5. **Monthly budget amount** and recipients for `google_billing_budget`.
6. **Is runtime security (Falco/Tetragon) required on cloud clusters?** Google does not support custom eBPF on DPv2
   nodes; it may still work on Standard. Options: run it on Standard and accept the risk (test on the first cluster
   for interference with `anetd`), use a managed alternative (GKE Security Posture, an allowlisted partner sensor),
   or keep it on Talos only.
7. **Google account without an Organization:** projects without an org cannot use org policies or folders. Fine
   for now? **(verify whether the account has a Cloud Identity org)**.
8. Things to confirm on the first real cluster: CCNP namespace-label selectors and `toEntities` on GKE;
   the metadata server allow (a Workload Identity call from a default-denied namespace succeeds, and fails without
   it); `CHANNEL_DISABLED` leaves no Gateway API CRDs; the `--dns-endpoint` flag; Hubble relay service name;
   cert-manager and ESO webhooks reachable on 10250 with no extra firewall rule.
9. **Spot risk:** one on-demand node for the baseline (Argo CD, cert-manager, ESO, Gateway, cloudflared) plus a
   Spot pool for tenants, or Spot only and accept that preemption or a stockout can take the whole cluster,
   GitOps included, offline?
10. **Cloudflare DNS-01 token ownership:** stays hand-made in the dashboard and stored only in the secrets backend,
    unless the secrets study finds a write-only or ephemeral token attribute that keeps the value out of state.
11. **FQDN egress with the CCNP default-deny:** the GKE FQDN doc only covers how `FQDNNetworkPolicy` combines with
    Kubernetes `NetworkPolicy`. Does an `FQDNNetworkPolicy` allow open egress for endpoints a CCNP default-deny
    selects? Test on the first cluster. And since tenants are blacklisted from `FQDNNetworkPolicy`, should the
    platform layer own per-tenant FQDN allowlists (a field in `gitops/tenants/<tenant>.yaml` rendered into the
    tenant namespace)?
