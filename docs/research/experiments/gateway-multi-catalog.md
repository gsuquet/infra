# Catalog rules from the Gateway API experiment

Proposals for the component catalog. Accepted ADRs win over this page. The
results behind each rule are in the [evidence](gateway-multi-evidence.md).

## CRD component

- `gateway-api-crds` owns the CRDs on kind and Talos: standard channel, pinned
  to **v1.6.3**, including the safe-upgrades VAP.
- Install it in Terraform during bootstrap (as planned) so Cilium starts with
  the CRDs present. If Cilium starts first, its operator must be restarted.
- It has no upstream Helm chart. Render it from the per-file CRDs at a tag with
  checksums (as `render.sh` does), or vendor the release
  `standard-install.yaml`. Renovate can track the tag; the checksum file must be
  regenerated in the same PR.
- Only `gateway-api-crds` may render CRDs in group `gateway.networking.k8s.io` or
  `gateway.networking.x-k8s.io`. The Conftest rule exists on `main`:
  [`policy/gateway_api/gateway_api.rego`](https://github.com/gsuquet/infra/blob/main/policy/gateway_api/gateway_api.rego).

## Proposal: VAP before the CRDs

This needs an RFC. [ADR-0005](https://github.com/gsuquet/infra/blob/main/docs/adr/0005-rendered-manifests-pattern.md) puts CRDs
in wave `-1` and ordinary resources in wave `0`, so the VAP would land after the
CRDs: the order that the one-pass rollback dry-run showed is denied.

- Put the VAP and its binding in sync wave **-2** and the CRDs in wave **-1**, so
  a bump and its revert both pass the VAP. The revert order is confirmed with
  kubectl; the VAP-first bump and Argo CD were not run.
- Give the `gateway-api-crds` Application `syncPolicy.retry` (for example
  `limit: 5`, `backoff.duration: 5s`), so a denied wave -1 is retried instead of
  failing the sync. The VAP has no health status, so Argo CD only waits its
  inter-wave delay ("2 seconds", `ARGOCD_SYNC_WAVE_DELAY`,
  [sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)).
  The [VAP propagation delay](gateway-multi-evidence.md#re-run-fresh-v163-and-vap-first-rollback)
  has no known bound. No measurement shows that it exceeds the wave delay.

## CRD version bump

A Gateway API minor bump needs a written procedure:

1. Bump `gateway-api-crds` first and on its own, within the range every
   implementation on the cluster supports. Read both projects' support tables,
   because nothing on the cluster warns about a mismatch.
2. If the [VAP proposal](#proposal-vap-before-the-crds) is accepted, its order
   applies on the way up and on the way back, and a rollback is a git revert.
   The v1.7.0 -> v1.6.3 order passed with kubectl; Argo CD was not tested. See the
   [caveat](gateway-multi-evidence.md#rollback-across-a-release-that-added-crds)
   on releases that added CRDs.
3. Restart `cilium-operator` after a bump that adds CRDs (as the Cilium upgrade
   procedure does); agentgateway needs no restart.
4. Do not switch channel in place. Pick standard now.
5. Check served and storage versions on every bump. They did not change between
   v1.5.1, v1.6.3 and v1.7.0 (`v1` is the storage version everywhere except
   ReferenceGrant, still stored as `v1beta1`), so no storage migration was needed.

Moving to Gateway API v1.7 waits until both Cilium (next minor, unverified) and
agentgateway list v1.7 as supported.

## GKE

GKE owns the CRDs: the catalog skips `gateway-api-crds` there
([ADR-0012](https://github.com/gsuquet/infra/blob/main/docs/adr/0012-gateway-api-crd-ownership.md)). GKE's CRD version is then
the constraint for agentgateway's support range. Nothing was tested on GKE.

- Enabling GKE's managed Gateway API (`--gateway-api=standard`) "instructs GKE
  to install the CRDs of the Gateway API Standard Channel with the cluster", and
  "GKE Gateway only supports the Gateway API Standard release channel"
  ([GKE: deploying Gateways](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/deploying-gateways)).
- The page does not say how GKE upgrades those CRDs or whether it overwrites
  self-installed ones.

## Implementations

- Cilium: `gatewayAPI.enabled: true`, `gatewayAPI.gatewayClass.create: "true"`
  (never `auto` with rendered manifests). Skipped on GKE as planned.
- agentgateway: both charts (`agentgateway-crds` at wave -1),
  `istio.enabled: false`.

## GatewayClass

- A GatewayClass is rendered into `rendered/` when the chart can template it
  (Cilium, with `gatewayClass.create: "true"`).
- A controller-managed GatewayClass (agentgateway) is an accepted, documented
  exception, declared in the component's `component.yaml` (for example
  `gatewayClass: {name: agentgateway, managedBy: controller}`).
- Conftest and kubeconform only see `rendered/`, so they need no allow-list; a
  cluster check (or the kind e2e job, once it exists) asserts that every declared
  GatewayClass is `Accepted`.
- Committing agentgateway's GatewayClass in git was not tested and stays a
  follow-up, not the default.
