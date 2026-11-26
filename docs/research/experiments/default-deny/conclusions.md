# Default-deny conclusions

<!-- readability: allow-code V2 L7 -->

Effect of [the results](results.md) on the plan. This page decides nothing: a change to an accepted record is a proposed
amendment or an open question.

## Conclusions for the plan

- **The design holds on single-node kind.** A label-selected CCNP default-deny plus component and tenant allow profiles
  gave the expected isolation for intra-namespace, Git, ACME, metrics, gateway and tenant flows. The limit of the webhook
  rule is in [Webhooks need their rule](results.md#webhooks-need-their-rule).
- **The `network-policy` component hosts the policies** (RFC 0010 and RFC 0014 in [PR 18](https://github.com/gsuquet/infra/pull/18)): the default deny and the component
  allows. Kubelet-probe allows are not in either RFC: they exist only under `allow-localhost: policy`, which is an
  [open question](#localhost-policy-beyond-the-experiment). If the default deny lands before a component's allows, that component breaks while
  its pods stay Ready. The order "allows before default deny" was not tested: landing them in the same or an earlier sync
  wave is a recommendation, not a measured requirement.
- **Bootstrap delivery of the Argo CD allows stays open.** Terraform applies `rendered/argocd/`, after the cluster, the
  Gateway API CRDs and Cilium ([ADR-0015](https://github.com/gsuquet/infra/blob/main/docs/adr/0015-bootstrap-boundary.md)). If the default deny lands before Argo CD's own allows, Argo CD cannot
  reach redis or GitHub and cannot adopt anything. Recommendation, not run: ship the Argo CD CNPs inside
  `rendered/argocd/`, and let Argo CD apply the default deny after it is healthy. Counter-evidence:
  Argo CD [compared without a restart](results.md#argo-cd-compares-after-a-late-policy) once late CNPs landed (`B0`), for an
  Application with no recorded `ComparisonError`. The run applied every policy with `kubectl`; Argo CD never applied
  `network-policy`. The settled owner of the policies is `network-policy`, so how Argo CD's allows arrive during bootstrap
  is the ADR-0015 row of the [proposed amendments](#proposed-amendments).
- **Argo CD and Pod Security Admission stop tenants, not Cilium.** Cilium cannot stop an allow it is given. The AppProject
  `namespaceResourceBlacklist` covers policy objects but not pod specs; the tenant `restricted` label (not run; [ADR-0009](https://github.com/gsuquet/infra/blob/main/docs/adr/0009-tenant-onboarding-by-infra.md)) is the platform control for pod
  specs: `baseline` rejected the `hostNetwork` pod in run 4, which would otherwise escape every policy. Conftest must fail a tenant namespace without a Pod Security label. Tenant Kubernetes RBAC must deny the same
  kinds if tenants ever get `kubectl` access.
- **Use clusterwide `egressDeny` for hard limits, on tenant namespaces only.** Nobody can override a deny (documented; run against one tenant allow). Select on
  `infra.gsuquet.com/tenant` existing, never on every policed namespace. On GKE, pods get Workload Identity tokens from
  the GKE metadata server at `169.254.169.254`. ESO needs that if the secrets backend becomes GCP Secret Manager, and a
  blanket deny could not be lifted for it afterwards. Candidates: the metadata IP and maybe the node CIDRs.
- **Readiness does not prove policy.** The deferred kind e2e CI job should reuse this script's functional checks: webhook
  call, Git compare, metrics scrape.
- **GKE needs its own run.** GKE Dataplane V2 accepts `CiliumClusterwideNetworkPolicy`
  ([GKE docs: Dataplane V2](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2)). Cilium warns that
  `kube-apiserver` may not work for ingress on GKE ([Cilium docs: layer 3](https://docs.cilium.io/en/stable/security/policy/layer3/)). Whether GKE supports `toFQDNs`,
  DNS L7 rules and `enableDefaultDeny` is **unverified**. Expect a GKE variant for webhook ingress (control-plane CIDR)
  and FQDN egress.

## Proposed amendments

| Record | Proposal | Reason |
| --- | --- | --- |
| [ADR-0009](https://github.com/gsuquet/infra/blob/main/docs/adr/0009-tenant-onboarding-by-infra.md) | Blacklist `cilium.io/*` instead of `CiliumNetworkPolicy` only | every namespaced Cilium kind (`CiliumEnvoyConfig`, `CiliumLocalRedirectPolicy`) can open or redirect traffic |
| [ADR-0010](https://github.com/gsuquet/infra/blob/main/docs/adr/0010-cluster-owned-default-deny-network-policy.md) | Record the GKE documentation on CCNP support, and the creation-time flag `enableCiliumClusterwideNetworkPolicy: true`, which `main` does not name | the record marks support unverified; RFC 0010 in [PR 18](https://github.com/gsuquet/infra/pull/18) states both |
| [ADR-0015](https://github.com/gsuquet/infra/blob/main/docs/adr/0015-bootstrap-boundary.md) | State how the Argo CD allows arrive during bootstrap, and when `network-policy` syncs | [bootstrap order](#conclusions-for-the-plan) |

[ADR-0014](https://github.com/gsuquet/infra/blob/main/docs/adr/0014-baseline-components.md) on `main` lists the baseline without `network-policy`; [PR 18](https://github.com/gsuquet/infra/pull/18) adds it.

## Open questions

### Baseline kube-apiserver egress

Should every pod get it, tenants included? Most tenant apps never call the API, and a tenant-only profile without it would
shrink the attack surface. [ADR-0010](https://github.com/gsuquet/infra/blob/main/docs/adr/0010-cluster-owned-default-deny-network-policy.md) gives it to everyone.

### Unlabelled namespaces

Add a `ValidatingAdmissionPolicy` that rejects namespaces without the policy label, so namespaces outside Git are covered
too, or label them from bootstrap? [ADR-0010](https://github.com/gsuquet/infra/blob/main/docs/adr/0010-cluster-owned-default-deny-network-policy.md) defers the admission check.

### Multi-node

Check a webhook on a worker **and** on a control-plane node: only the worker can show that
`fromEntities: kube-apiserver` is narrower than `host`. Run `KIND_CONFIG=kind-multinode.yaml run.sh` (untested) on a host
with 8 GiB free for kind, or check it on the first Talos Pi cluster.

### Localhost policy beyond the experiment

Keep `allow-localhost: policy` on kind and Talos? It closes host-network to local pod traffic, but the policies must then
hold correct kubelet-probe allows, and a wrong port shows up as a NotReady pod. Whether GKE Dataplane V2 exposes the
option is **unverified**.

### Metadata IP and Workload Identity

Tie the tenant-only metadata deny to the secrets-backend study: if GCP Secret Manager wins, ESO keeps metadata access, and
tenants that need GCP APIs need a design of their own.

### Value of the policy label

Keep only `default-deny`, or reserve another value (for example `audit`) for a migration period? Cilium's audit mode is
per agent or per endpoint, not per namespace label, so it would need more design.
