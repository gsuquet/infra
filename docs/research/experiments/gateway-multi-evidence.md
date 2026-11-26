# Evidence: one Gateway API CRD owner, two implementations

<!-- readability: allow-code L2 -->

Results and recommendations: [experiment summary](gateway-multi.md).

## Goal

Check the settled Gateway API design before it goes into the component catalog:

- One component, `gateway-api-crds`, owns every `gateway.networking.k8s.io` CRD.
- Cilium's Gateway API is enabled without Cilium installing CRDs.
- A second implementation (agentgateway) is installed without its own copy of
  the Gateway API CRDs, with its own GatewayClass.
- Both GatewayClasses are accepted and route traffic.
- Find the version and channel constraints between Cilium, agentgateway and the
  CRD bundle, and what a CRD version bump does.

## Runs

| Runs | Script | Parameters | Result |
| --- | --- | --- | --- |
| Earlier, three | third run used the committed scripts | `GWAPI_FROM=v1.5.1 GWAPI_BUMPS="v1.6.3 v1.7.0"` | same results each time, end to end |
| Re-run, two, 2026-11-19 | see [What the runs prove](#what-the-runs-prove) | defaults: fresh v1.6.3, bump to v1.7.0, rollback | exit 0, cluster deleted both times |

## Setup

| Item | Version |
| --- | --- |
| kind | 0.33.0, node `kindest/node:v1.37.0` by digest, full value in [`kind.yaml`](../../../experiments/gateway-multi/kind.yaml) (Kubernetes 1.37.0), single node, no default CNI, `kubeProxyMode: none` |
| kubectl / helm / yq | 1.37.2 / 4.3.2 / 4.54.3 (`experiments/gateway-multi/mise.toml` + `mise.lock`) |
| Gateway API CRDs | standard channel; earlier runs: start v1.5.1, bumped to v1.6.3 then v1.7.0; re-run: fresh v1.6.3, bump to v1.7.0, rollback to v1.6.3; per-file CRDs from `raw.githubusercontent.com/kubernetes-sigs/gateway-api/<tag>/config/crd/standard/`, checked against `components/gateway-api-crds/checksums/<tag>-standard.sha256` |
| Cilium chart | 1.20.5 (`https://helm.cilium.io`), `kubeProxyReplacement: true`, `gatewayAPI.enabled: true`, `gatewayAPI.gatewayClass.create: "true"`, Hubble off |
| agentgateway charts | `agentgateway-crds` v1.7.0 and `agentgateway` v1.7.0 (`oci://cr.agentgateway.dev/charts/…`), `istio.enabled: false` |
| Test images | `registry.k8s.io/e2e-test-images/agnhost:2.56` (`netexec`), `curlimages/curl:8.17.0` (tags, not digests) |

Pinning is uneven: Gateway API CRDs (checksums) and the kind node image
(digest) are immutable, but the Cilium chart, the agentgateway OCI charts and
both test images are pinned by tag, and tags are mutable. The catalog must
record chart and image digests (TODO comments in the component files). The
re-run's `helm template` printed the OCI digests it pulled. They were observed
once, not recorded in `component.yaml`. Only these prefixes were kept, so they
cannot serve as pins (fetch the full values again):
`agentgateway-crds:v1.7.0` `sha256:946b739c…`,
`agentgateway:v1.7.0` `sha256:40340d63…`. The Cilium 1.20.5 chart renders its
images by digest (`cilium:v1.20.5@sha256:aa72499f…`,
`operator-generic:v1.20.5@sha256:c6e7de66…`); the agentgateway chart renders
`cr.agentgateway.dev/controller:v1.7.0` by tag only.

Host: Colima (4 CPUs, 7.7 GiB) with another 2-node kind cluster running
(about 2 GiB used; 2056 MiB at the re-run's preflight). The highest sampled
usage of the experiment node was 1.33 GiB in the earlier runs and 1.43 GiB in
the re-run (after the rollback) (single `docker stats --no-stream` samples per phase, not a measured
peak; Cilium,
cilium-envoy, agentgateway controller and two proxies, backend). `run.sh`
refuses to start when existing kind nodes leave less than `MIN_FREE_MIB`
(default 3 GiB). A full run takes about 5 minutes with warm image caches
(the second re-run: about 3 minutes from render to cluster deletion).

All charts are installed the way the plan installs them: `render.sh` runs
`helm template` per component, then `kubectl apply --server-side`. The order
mirrors the bootstrap boundary: CRDs, then Cilium, then everything else.

Gateways get addresses from a Cilium LB-IPAM pool (`172.18.255.200-220`)
without L2 announcements, so the probes run from a `curl` pod inside the
cluster. Each Gateway has one HTTPRoute (`cilium.example.test`,
`agentgateway.example.test`) pointing at the same `echo` Service; the probe is
`curl -H "Host: <host>" http://<gateway address>/hostname`.

## Bundled CRDs: none, but check every render

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
it). On `main`, the [Conftest rule](gateway-multi-catalog.md#crd-component)
makes the same check.

## Both GatewayClasses accepted, both route

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

## CRD bumps: v1.5.1 -> v1.6.3 -> v1.7.0 (earlier runs)

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

## Re-run: fresh v1.6.3 and VAP-first rollback

Two runs of `run.sh` on 2026-11-19 with its defaults (`GWAPI_FROM=v1.6.3`,
`GWAPI_BUMPS=v1.7.0`), same tool and chart versions as in [Setup](#setup).
Both exited 0 and deleted `exp-gateway-multi`; what that proves is in
[What the runs prove](#what-the-runs-prove). Every probe passed in both runs:

| Phase | cilium | agentgateway | Notes |
| --- | --- | --- | --- |
| v1.6.3 fresh (CRDs before Cilium) | OK | OK | Cilium's operator enabled every optional route at its **first** start, no restart needed. agentgateway logged no `failed to list`. |
| v1.7.0, no restart | OK | OK | |
| v1.7.0, restarted | OK | OK | |
| v1.6.3 after rollback, restarted | OK | OK | All ten CRDs back at `bundle-version` v1.6.3. |

No `level=warn` or `level=error` line in any captured cilium-operator or
agentgateway log (four snapshots of two logs per run). The last snapshot runs
before the controllers restart after the rollback, so the logs of the restarted
controllers were not captured.

Fresh install, first operator start:

```text
level=info msg="Checking for required and optional GatewayAPI resources" …
level=info msg="ListenerSet CRD is installed, ListenerSet support is enabled"
level=info msg="TCPRoute CRD is installed, TCPRoute support is enabled"
level=info msg="UDPRoute CRD is installed, UDPRoute support is enabled"
```

```text
[v1.6.3] cilium via 172.18.255.200 -> echo-7bbdbbc65f-xpz97
[v1.6.3] agentgateway via 172.18.255.201 -> echo-7bbdbbc65f-xpz97
…
[v1.6.3-rollback] cilium via 172.18.255.200 -> echo-7bbdbbc65f-xpz97
[v1.6.3-rollback] agentgateway via 172.18.255.201 -> echo-7bbdbbc65f-xpz97
```

Rollback v1.7.0 -> v1.6.3. The one-pass dry-run (whole directory, VAP file
last) was denied for **all ten** CRDs with the v1.7.0 VAP's message, as
predicted. Then the VAP and binding were applied alone, and the CRD directory
right after:

```text
=== rollback v1.7.0 -> v1.6.3, VAP + binding first, then CRDs (real apply)
validatingadmissionpolicy.admissionregistration.k8s.io/safe-upgrades.gateway.networking.k8s.io serverside-applied
validatingadmissionpolicybinding.admissionregistration.k8s.io/safe-upgrades.gateway.networking.k8s.io serverside-applied
attempt 1 at +0.0s after the VAP apply
rollback CRD apply attempt 1 denied:
Error from server (Invalid): customresourcedefinitions.apiextensions.k8s.io "backendtlspolicies.gateway.networking.k8s.io"
  is forbidden: ValidatingAdmissionPolicy 'safe-upgrades.gateway.networking.k8s.io' … denied request:
  Installing CRDs with version before v1.7.0 is prohibited by default. …
attempt 2 at +1.4s after the VAP apply
rollback CRD apply succeeded on attempt 2
```

(Run 2. Run 1 had no timestamps: attempt 1 was denied for all ten CRDs,
attempt 2 after a 3 s sleep plus one apply passed.) The API server kept
evaluating CRDs against the **old** v1.7.0 VAP after the new VAP object was
stored: the policy reaches admission through an informer. So the VAP-first
order works, but **not instantly**. In run 2, attempt 2 started about 1.4 s after
the VAP apply returned. In run 1, the passing attempt came at most about 4 s after
(estimated, not timed). Two samples are not a bound.

### What the runs prove

- The two runs used different scripts: run 1 the loop at commit `9903b0d`
  (5 tries, 3 s apart, no timestamps), run 2 the loop at commit `abff64f`
  (10 tries, 1 s apart, timestamps).
- Exit 0 proves little: `run.sh` prints a denied rollback, and a failed probe
  after a bump without restart or after the rollback, and still exits 0.
  The evidence is the printed probe and apply lines, excerpted above for run 2.
  Run 1 rests on the log of the person who ran it, with no excerpt here.

## The safe-upgrades ValidatingAdmissionPolicy and rollbacks

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
   After the bump to v1.7.0, the earlier runs dry-ran a downgrade to
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

The [re-run](#re-run-fresh-v163-and-vap-first-rollback) confirmed this with
kubectl. An Argo CD sync with waves was not tested.

Side note from the VAP source: the v1.6.3 VAP message says "before v1.5.0"
although its regex denies v1.5.x too.

### Rollback across a release that added CRDs

A rollback that crosses a release which added CRDs (for example v1.6 -> v1.5 drops `tcproutes` and
`udproutes` from standard) leaves those CRDs behind unless Argo CD prunes
them, which would delete every object of that kind.

## Version and channel compatibility

| Component | Gateway API it supports | Source |
| --- | --- | --- |
| Cilium 1.20.x | **v1.6.3** ("Cilium supports Gateway API v1.6.3"), minimum **v1.6.1** ("requires Gateway API v1.6.1 at a minimum to work correctly"). Required: GatewayClass, Gateway, HTTPRoute, GRPCRoute, TLSRoute, ReferenceGrant, BackendTLSPolicy. Optional: ListenerSet, TCPRoute, UDPRoute. | [Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/), [1.20 upgrade notes](https://docs.cilium.io/en/stable/operations/upgrade/) |
| agentgateway 1.7.x | **v1.4 – v1.6**, Kubernetes 1.32 – 1.37 | [agentgateway version table](https://agentgateway.dev/docs/kubernetes/latest/release-notes/versions/) |
| Gateway API standard v1.6.3 | Has every resource Cilium 1.20 requires, plus TCPRoute/UDPRoute at `v1` (new in standard in v1.6) | CRD files at the tag |

The only Gateway API minor both support is **v1.6**, hence the
[pin](gateway-multi-catalog.md#crd-component). v1.5.1 and v1.7.0 both worked here
for HTTPRoute, but v1.5.1 is below Cilium's minimum and v1.7.0 is outside both
support statements.

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
  See the [GatewayClass rule](gateway-multi-catalog.md#gatewayclass).
- **Cilium ships its own VAP** (`gateway.cilium.io`) that rejects `cilium`
  Gateways whose TLS `Terminate` listeners do not have exactly one
  certificateRef. It matches all Gateways but only applies to
  `gatewayClassName: cilium`.
- **The default agentgateway chart needs Istio CRDs for RBAC.** `istio.enabled`
  defaults to `true`; set it to `false` when Istio is not installed.
- The no-restart window after each bump was only 10 seconds plus the probe
  time. A longer soak was not run.

## Unverified

- Cilium's support for Gateway API v1.7.0 (no Cilium release note found; it
  worked here for HTTPRoute only).
- Whether a GatewayClass committed in git conflicts with agentgateway's own
  GatewayClass reconciliation.
- Argo CD itself: the wave -2/-1 split, the 2 s wave delay versus the VAP
  propagation delay, and `syncPolicy.retry` recovering a denied wave -1. The
  re-run only replays the order with kubectl. Also untested: how Argo CD orders
  a VAP against CRDs inside a **single** wave, and whether a failed one-wave
  sync converges on retry (the VAP would already be updated by the first
  attempt).
- An upper bound for the VAP propagation delay: two samples on an idle
  single-node cluster.
- GKE's managed Gateway API CRD lifecycle (upgrades, coexistence with
  self-installed CRDs).
- Chart and image digests: see [Setup](#setup).
- GRPCRoute, TLSRoute, TCPRoute and UDPRoute traffic: only HTTPRoute was
  routed.
- Behaviour on Talos with L2 announcements or BGP; only in-cluster traffic to
  LB-IPAM addresses was tested.
