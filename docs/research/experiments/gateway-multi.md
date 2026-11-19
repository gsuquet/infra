# Experiment: one Gateway API CRD owner, two implementations

Status: **passed.** On single-node kind, Cilium 1.20.5 and agentgateway v1.7.0
both accepted their GatewayClass and routed an HTTPRoute to the same backend,
with the Gateway API CRDs owned by one standalone component. Both kept routing
through CRD bumps v1.5.1 -> v1.6.3 -> v1.7.0, with and without controller
restarts. The script ran three times end to end with the same results; the
third run used the committed scripts. The interesting results are the
constraints around those bumps, not the happy path.

After review, `run.sh` changed: it now defaults to a **fresh v1.6.3 install**
(the recommended pin) with one bump to v1.7.0, and ends with a real
v1.7.0 -> v1.6.3 rollback that applies the safe-upgrades VAP before the CRDs.
**That revised run has not been executed yet**; the results below come from the
earlier runs (`GWAPI_FROM=v1.5.1 GWAPI_BUMPS="v1.6.3 v1.7.0"`). Sections that
depend on the pending run say so.

Scripts: [`experiments/gateway-multi/`](../../../experiments/gateway-multi/).
`experiments/gateway-multi/run.sh` creates the kind cluster `exp-gateway-multi`,
runs every step, writes evidence to `$OUT` (default: a `mktemp` directory) and
always deletes the cluster (`KEEP=1` keeps it).

## Goal

Check the settled Gateway API design before it goes into the component catalog:

- One component, `gateway-api-crds`, owns every `gateway.networking.k8s.io` CRD.
- Cilium's Gateway API is enabled without Cilium installing CRDs.
- A second implementation (agentgateway) is installed without its own copy of
  the Gateway API CRDs, with its own GatewayClass.
- Both GatewayClasses are accepted and route traffic.
- Find the version and channel constraints between Cilium, agentgateway and the
  CRD bundle, and what a CRD version bump does.

## Setup

| Item | Version |
| --- | --- |
| kind | 0.33.0, node `kindest/node:v1.37.0@sha256:a1ed56cf…` (Kubernetes 1.37.0), single node, no default CNI, `kubeProxyMode: none` |
| kubectl / helm / yq | 1.37.2 / 4.3.2 / 4.54.3 (`experiments/gateway-multi/mise.toml` + `mise.lock`) |
| Gateway API CRDs | standard channel; recorded runs: start v1.5.1, bumped to v1.6.3 then v1.7.0; per-file CRDs from `raw.githubusercontent.com/kubernetes-sigs/gateway-api/<tag>/config/crd/standard/`, checked against `components/gateway-api-crds/checksums/<tag>-standard.sha256` |
| Cilium chart | 1.20.5 (`https://helm.cilium.io`), `kubeProxyReplacement: true`, `gatewayAPI.enabled: true`, `gatewayAPI.gatewayClass.create: "true"`, Hubble off |
| agentgateway charts | `agentgateway-crds` v1.7.0 and `agentgateway` v1.7.0 (`oci://cr.agentgateway.dev/charts/…`), `istio.enabled: false` |
| Test images | `registry.k8s.io/e2e-test-images/agnhost:2.56` (`netexec`), `curlimages/curl:8.17.0` (tags, not digests) |

Pinning is uneven: Gateway API CRDs (checksums) and the kind node image
(digest) are immutable, but the Cilium chart, the agentgateway OCI charts and
both test images are pinned by tag, and tags are mutable. The catalog must
record chart and image digests (TODO comments in the component files); the
digests were not looked up here.

Host: Colima (4 CPUs, 7.7 GiB) with another 2-node kind cluster running
(about 2 GiB used). The highest sampled usage of the experiment node was
1.33 GiB (single `docker stats --no-stream` samples per phase, not a measured
peak; Cilium,
cilium-envoy, agentgateway controller and two proxies, backend). `run.sh`
refuses to start when existing kind nodes leave less than `MIN_FREE_MIB`
(default 3 GiB). A full run takes about 5 minutes with warm image caches.

All charts are installed the way the plan installs them: `render.sh` runs
`helm template` per component, then `kubectl apply --server-side`. The order
mirrors the bootstrap boundary: CRDs, then Cilium, then everything else.

Gateways get addresses from a Cilium LB-IPAM pool (`172.18.255.200-220`)
without L2 announcements, so the probes run from a `curl` pod inside the
cluster. Each Gateway has one HTTPRoute (`cilium.example.test`,
`agentgateway.example.test`) pointing at the same `echo` Service; the probe is
`curl -H "Host: <host>" http://<gateway address>/hostname`.

## Results

### Bundled CRDs: none, but check every render

Neither implementation bundles Gateway API CRDs:

- The Cilium 1.20.5 chart renders **zero** CRDs. Cilium's operator creates its
  own `cilium.io` CRDs at runtime (`--skip-crd-creation='false'`), never the
  Gateway API ones. The Cilium docs say the same: install the CRDs yourself.
- `agentgateway-crds` v1.7.0 only carries `agentgateway.dev` CRDs
  (`agentgatewaybackends`, `agentgatewaymodels`, `agentgatewayparameters`,
  `agentgatewaypolicies`). The install guide installs Gateway API CRDs
  separately with `kubectl apply --server-side`.

So "install without bundled CRDs" needs no flag for either. `render.sh` still
fails if any component other than `gateway-api-crds` renders a CRD in group
`gateway.networking.k8s.io` or `gateway.networking.x-k8s.io` (checked by
appending the Gateway API HTTPRoute CRD to the Cilium render: the guard names
it). That check should
become a Conftest rule over `rendered/`, so a future chart that starts bundling
them is caught in CI.

### Both GatewayClasses accepted, both route

```text
NAME           CONTROLLER                      ACCEPTED   AGE   DESCRIPTION
agentgateway   agentgateway.dev/agentgateway   True       1s    Specialized class for agentgateway.
cilium         io.cilium/gateway-controller    True       52s   The default Cilium GatewayClass

NAMESPACE   NAME                                                CLASS          ADDRESS          PROGRAMMED
demo        gateway.gateway.networking.k8s.io/gw-agentgateway   agentgateway   172.18.255.201   True
demo        gateway.gateway.networking.k8s.io/gw-cilium         cilium         172.18.255.200   True

[v1.5.1] cilium via 172.18.255.200 -> echo-7bbdbbc65f-gw8x8
[v1.5.1] agentgateway via 172.18.255.201 -> echo-7bbdbbc65f-gw8x8
```

The two controllers ignore each other's Gateways. Cilium's operator logs
`GatewayClass does not have matching controller name, cleaning up previously
managed resources` for `gw-agentgateway`, which is harmless. Its GAMMA
controller also reconciles the agentgateway Service, which is harmless too.

Cilium LB-IPAM gives an address to **every** `LoadBalancer` Service, so the
agentgateway proxy Service got one from the Cilium pool as well. On Talos that
is what we want; on GKE (no Cilium) the cloud load balancer takes over.

### CRD bumps: v1.5.1 -> v1.6.3 -> v1.7.0

Every phase passed the probe for both implementations:

| Phase | cilium | agentgateway | Notes |
| --- | --- | --- | --- |
| v1.5.1 (start) | OK | OK | Below Cilium 1.20's documented minimum (v1.6.1). No warning from either controller. agentgateway logs one `failed to list *v1.TCPRoute: the server could not find the requested resource` (TCPRoute is not in v1.5.1 standard) and carries on. |
| v1.6.3, no restart | OK | OK | agentgateway's CRD watcher picks up the new `tcproutes`/`udproutes` at once. Cilium does not. |
| v1.6.3, operator restarted | OK | OK | Only now does Cilium log `TCPRoute CRD is installed, TCPRoute support is enabled` and the same for UDPRoute. |
| v1.7.0, no restart | OK | OK | v1.7.0 is outside both support statements (see below). Nothing breaks for HTTPRoute. |
| v1.7.0, restarted | OK | OK | Same. |

No GatewayClass reported a version problem in any phase: both only set
`Accepted=True`, and neither sets a condition about the installed CRD version.
**A CRD/implementation mismatch is silent**; the only guard is our own pinning.

Cilium checks for CRDs **once, at operator start-up**:

```text
level=info msg="Checking for required and optional GatewayAPI resources"
  requiredGVK="[gateway.networking.k8s.io/v1, Kind=gatewayclasses …gateways …httproutes
               …grpcroutes …tlsroutes …referencegrants …backendtlspolicies]"
  optionalGVK="[gateway.networking.k8s.io/v1, Kind=listenersets
               multicluster.x-k8s.io/v1beta1, Kind=serviceimports
               gateway.networking.k8s.io/v1, Kind=tcproutes
               gateway.networking.k8s.io/v1, Kind=udproutes]"
level=info msg="TCPRoute CRD is installed, TCPRoute support is enabled"
```

So a bump that **adds** a CRD needs a `cilium-operator` restart before Cilium
uses it. Required GVKs include `tlsroutes` and `backendtlspolicies` at `v1`;
both are in the **standard** channel from v1.5.1 on.

### The safe-upgrades ValidatingAdmissionPolicy and rollbacks

All three bundles tested (v1.5.1, v1.6.3, v1.7.0) ship the
ValidatingAdmissionPolicy `safe-upgrades.gateway.networking.k8s.io` next to the
CRDs, in the standard channel too. Its two rules:

1. It denies experimental-channel CRDs on top of standard-channel ones:

   ```text
   ValidatingAdmissionPolicy 'safe-upgrades.gateway.networking.k8s.io' … denied request:
   Installing experimental CRDs on top of standard channel CRDs is prohibited by default.
   ```

2. It denies any CRD whose `bundle-version` annotation is older than a version
   **set by the installed bundle**. The regex moves with each release:
   `v1.[0-4].\d+` in v1.5.1, `v1.[0-5].\d+` in v1.6.3, `v1.[0-6].\d+` in v1.7.0.
   After the bump to v1.7.0, the recorded runs dry-ran a downgrade to
   **v1.5.1** (the start version then), applying the whole directory, and it
   was denied with the v1.7.0 VAP's message:

   ```text
   Error from server (Invalid): customresourcedefinitions.apiextensions.k8s.io
   "httproutes.gateway.networking.k8s.io" is forbidden: ValidatingAdmissionPolicy
   'safe-upgrades.gateway.networking.k8s.io' … denied request: Installing CRDs with
   version before v1.7.0 is prohibited by default.
   ```

That denial depends on **apply order**, so it does not prove that a minor bump
is irreversible. `kubectl apply -f <dir>` processes files by name, so
`gateway.networking.k8s.io_vap_safeupgrades.yaml` goes last and every CRD is
checked against the newer VAP still on the cluster. The VAP only matches
`customresourcedefinitions`, so it never blocks its own replacement. Reading
the upstream v1.6.3 VAP (sha256 `66b1d7b2…`, the committed checksum): it
denies `bundle-version` `v1.[0-5].x` only, so once the v1.6.3 VAP replaces
the v1.7.0 one, the v1.6.3 CRDs pass. A rollback that applies the VAP and its
binding **first** and the CRDs **second** should therefore succeed.

Status: **pending**. `run.sh` now runs exactly that (`rollback v1.7.0 ->
v1.6.3`: a one-pass dry-run that should be denied, then VAP first and CRDs
second for real, retried briefly because VAP changes reach the API server
through an informer, then a probe). It has not been executed since the
change, and an Argo CD sync with waves was never tested.

Two side notes from the VAP source: the v1.6.3 VAP message says "before
v1.5.0" although its regex denies v1.5.x too, and a rollback that crosses a
release which added CRDs (for example v1.6 -> v1.5 drops `tcproutes` and
`udproutes` from standard) leaves those CRDs behind unless Argo CD prunes
them, which would delete every object of that kind.

### Version and channel compatibility

| Component | Gateway API it supports | Source |
| --- | --- | --- |
| Cilium 1.20.x | **v1.6.3** ("Cilium supports Gateway API v1.6.3"), minimum **v1.6.1** ("requires Gateway API v1.6.1 at a minimum to work correctly"). Required: GatewayClass, Gateway, HTTPRoute, GRPCRoute, TLSRoute, ReferenceGrant, BackendTLSPolicy. Optional: ListenerSet, TCPRoute, UDPRoute. | [Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/), [1.20 upgrade notes](https://docs.cilium.io/en/stable/operations/upgrade/) |
| agentgateway 1.7.x | **v1.4 – v1.6**, Kubernetes 1.32 – 1.37 | [agentgateway version table](https://agentgateway.dev/docs/kubernetes/latest/release-notes/versions/) |
| Gateway API standard v1.6.3 | Has every resource Cilium 1.20 requires, plus TCPRoute/UDPRoute at `v1` (new in standard in v1.6) | CRD files at the tag |

The only Gateway API minor both support is **v1.6**, so pin
`gateway-api-crds` to **v1.6.3, standard channel**. v1.5.1 and v1.7.0 both
worked here for HTTPRoute, but each one is outside one project's support
statement.

Why standard, not experimental:

- Cilium 1.20 needs no experimental resource: TLSRoute and BackendTLSPolicy
  are standard at `v1`. Experimental is only needed for experimental fields
  (Cilium cites HTTPRoute retries).
- The VAP forbids switching from standard to experimental in place, and the
  Gateway API docs warn that experimental upgrades may need an uninstall and
  reinstall. Switching later means deleting the VAP, which is a manual step
  outside GitOps.
- One exception from the Cilium 1.20 upgrade notes: a cluster that **already
  stores** TLSRoute objects at `v1alpha2` must install the experimental
  TLSRoute CRD from v1.6.1, or the API server cannot read them back. That only
  matters when migrating an existing cluster with TLSRoutes; the new clusters
  start clean.

### What a CRD version bump does (rules for the catalog)

1. Bump `gateway-api-crds` first and on its own, within the range every
   implementation on the cluster supports. Read both projects' support tables,
   because nothing on the cluster warns about a mismatch.
2. Restart `cilium-operator` after a bump that adds CRDs (as the Cilium upgrade
   procedure does); agentgateway needs no restart.
3. Apply the safe-upgrades VAP and its binding before the CRDs, on the way up
   and on the way back. With that order, a rollback should be a normal git
   revert (static reading of the VAP, runtime test pending). In one pass with
   the VAP last, a minor rollback is denied.
4. Do not switch channel in place. Pick standard now.
5. Served and storage versions did not change between v1.5.1, v1.6.3 and
   v1.7.0 (`v1` is the storage version everywhere except ReferenceGrant, still
   stored as `v1beta1`). That is why no storage migration was needed here; check
   it again on every bump.

## What failed or surprised

- **Cilium `gatewayClass.create: auto` drops the GatewayClass in `helm
  template`.** `auto` checks `.Capabilities.APIVersions.Has
  "gateway.networking.k8s.io/v1/GatewayClass"`, which is false without a
  cluster. The rendered manifests had no `cilium` GatewayClass and no
  `gateway.cilium.io` VAP until the value was forced to `"true"`. Every
  rendered component must check chart values that rely on `.Capabilities` or
  `lookup`.
- **agentgateway creates its GatewayClass at runtime.** The chart has no
  GatewayClass template: the controller creates `agentgateway` (and the
  per-Gateway proxy Deployment and Service) itself. Argo CD will not own or
  prune them, while Cilium's GatewayClass is rendered and owned by Argo CD.
  See the GatewayClass rule in the conclusions.
- **Cilium ships its own VAP** (`gateway.cilium.io`) that rejects `cilium`
  Gateways whose TLS `Terminate` listeners do not have exactly one
  certificateRef. It matches all Gateways but only applies to
  `gatewayClassName: cilium`.
- **The default agentgateway chart needs Istio CRDs for RBAC.** `istio.enabled`
  defaults to `true`; set it to `false` when Istio is not installed.
- The no-restart window after each bump was only 10 seconds plus the probe
  time. A longer soak was not run.

## Conclusions for the plan

- Keep **one owner** for Gateway API CRDs: `gateway-api-crds`, standard
  channel, pinned to **v1.6.3**, including the safe-upgrades VAP. Put the VAP
  and its binding in sync wave **-2** and the CRDs in wave **-1**, so a bump
  and its revert both pass the VAP. Also install it in Terraform during
  bootstrap (as planned) so Cilium starts with the CRDs present. If Cilium
  starts first, its operator must be restarted. A fresh v1.6.3 install before
  Cilium is what the revised `run.sh` does by default; it has not run yet.
- `gateway-api-crds` has no upstream Helm chart. Render it from the per-file
  CRDs at a tag with checksums (as `render.sh` does), or vendor the release
  `standard-install.yaml`. Renovate can track the tag; the checksum file must
  be regenerated in the same PR.
- Add a Conftest rule: only `gateway-api-crds` may render CRDs in group
  `gateway.networking.k8s.io` or `gateway.networking.x-k8s.io`.
- Cilium component values: `gatewayAPI.enabled: true`,
  `gatewayAPI.gatewayClass.create: "true"` (never `auto` with rendered
  manifests). Skipped on GKE as planned.
- **GKE rule (unverified, not tested):** enabling GKE's managed Gateway API
  (`--gateway-api=standard`) "instructs GKE to install the CRDs of the Gateway
  API Standard Channel with the cluster", and "GKE Gateway only supports the
  Gateway API Standard release channel"
  ([GKE: deploying Gateways](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/deploying-gateways)).
  The page does not say how GKE upgrades those CRDs or whether it overwrites
  self-installed ones. So GKE's Gateway controller is not a free choice next to
  agentgateway: it takes over CRD ownership and the version pin. Recommended
  default: keep GKE's managed Gateway API **disabled** and let
  `gateway-api-crds` own the CRDs (no GKE Gateway controller, agentgateway
  behind a cloud `LoadBalancer` Service or Cloudflare Tunnel). The alternative
  is to skip `gateway-api-crds` on GKE, as the catalog skips `cilium`, and
  accept GKE's CRD version as the constraint for agentgateway's support range.
  The owner decides; whichever is chosen goes into the GKE cluster module.
- agentgateway component: both charts (`agentgateway-crds` at wave -1),
  `istio.enabled: false`.
- **GatewayClass rule for the catalog:** a GatewayClass is rendered into
  `rendered/` when the chart can template it (Cilium, with
  `gatewayClass.create: "true"`); a controller-managed GatewayClass (agentgateway)
  is an accepted, documented exception, declared in the component's
  `component.yaml` (for example `gatewayClass: {name: agentgateway, managedBy:
  controller}`). Conftest and kubeconform only see `rendered/`, so they need no
  allow-list; a cluster check (or the kind e2e job, once it exists) asserts
  that every declared GatewayClass is `Accepted`. Committing agentgateway's
  GatewayClass in git was not tested and stays a follow-up, not the default.
- A Gateway API minor bump needs a written procedure: check every enabled
  implementation's support range, bump CRDs (VAP wave first), restart
  `cilium-operator`. Rollback is a git revert with the same wave order, once
  the pending rollback run confirms it.
- Upgrade coupling: moving to Gateway API v1.7 waits until both Cilium (next
  minor, unverified) and agentgateway list v1.7 as supported.

## Unverified

- Cilium's support for Gateway API v1.7.0 (no Cilium release note found; it
  worked here for HTTPRoute only).
- Whether a GatewayClass committed in git conflicts with agentgateway's own
  GatewayClass reconciliation.
- The revised `run.sh`: fresh v1.6.3 install and the VAP-first v1.7.0 ->
  v1.6.3 rollback (not executed since the change). Argo CD sync waves for the
  VAP were never tested.
- GKE's managed Gateway API CRD lifecycle (upgrades, coexistence with
  self-installed CRDs).
- Chart and image digests (only tags are pinned).
- GRPCRoute, TLSRoute, TCPRoute and UDPRoute traffic: only HTTPRoute was
  routed.
- Behaviour on Talos with L2 announcements or BGP; only in-cluster traffic to
  LB-IPAM addresses was tested.
