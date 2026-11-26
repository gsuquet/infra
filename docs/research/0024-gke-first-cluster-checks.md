# GKE first-cluster checks

Detail for [RFC 0024](../rfc/0024-gke.md); check date, sources and **(unverified)** marks: see its
[Context](../rfc/0024-gke.md#context).

## Before the default deny syncs

- CCNP namespace-label selectors and `toEntities`.
- Argo CD, cert-manager and cloudflared egress through `FQDNNetworkPolicy` under the CCNP.

When one fails, GKE uses the [NetworkPolicy fallback](0024-gke-network-policy.md#networkpolicy-fallback) for the selectors and for egress by
name, and `toCIDR` for the API server when `toEntities` is rejected.

## Before tenants are enabled

- A `CiliumNetworkPolicy` apply.
- A Workload Identity call from a default-denied namespace succeeds with the metadata allow and fails without it.
- GKE-managed kube-system pods and the `PreferNoSchedule` taint.
- kube-dns replica spread across pool classes.
- Which pool the autoscaler grows for Pending tenant pods, with and without a Spot-first `ComputeClass`.
- The `--dns-endpoint` flag.
- The Hubble relay service name.
- cert-manager and ESO webhooks reachable on 10250 without a firewall rule.
