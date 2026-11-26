# Default-deny pitfalls

Cilium behavior that [the runs](results.md) hit or that the Cilium documentation warns about.

## Host to local pod traffic is allowed by default

The Cilium layer-3 page states it: "Kubernetes will automatically allow all communication from the local host of all
local endpoints", and the agent option `--allow-localhost=policy` turns it off
([Cilium docs: layer 3, entities](https://docs.cilium.io/en/stable/security/policy/layer3/)). With the default, a one-node cluster hides webhook rules, because
kube-apiserver carries the host identity.

With `allow-localhost: policy`, every policed pod needs an explicit `fromEntities: host` allow on its kubelet probe
ports, and that allow must not cover webhook ports. The ports in `policies/kubelet-probes/` were sufficient in run 4:
every pod was Ready in phase A; argocd-redis and applicationset-controller needed no host allow. On a production cluster
the same switch also stops host-network pods on a node from reaching every local pod
([open question](conclusions.md#localhost-policy-beyond-the-experiment)).

## Host-network pods are not Cilium endpoints

CNPs and CCNPs do not select them, for example Talos static control-plane pods or a webhook with `hostNetwork: true`.
Policing them needs Cilium host policies (host firewall), a separate feature with its own known issues
([Cilium docs: host policies](https://docs.cilium.io/en/stable/security/policy/host/)). As sources, they appear as `host` or `remote-node`.

What this means for tenants is in
[Conclusions for the plan](conclusions.md#conclusions-for-the-plan).

## Remote-node is broad

Allowing `remote-node` lets in every node and every host-network pod on other nodes. Prefer `kube-apiserver`, a label on
top of `remote-node` (identity 7). North-south traffic forwarded between nodes can also arrive as `remote-node` in native
routing, and as `world` in tunnel mode ([Cilium docs: caveats](https://docs.cilium.io/en/stable/security/policy/caveats/)). Cloudflare Tunnel avoids this: cloudflared
is an in-cluster client that enters through the gateway namespace.

## DNS proxy

The baseline L7 DNS rule sends every lookup from a policed pod through the Cilium agent's DNS proxy, a requirement for
`toFQDNs` ([Cilium docs: layer 3, DNS-based](https://docs.cilium.io/en/stable/security/policy/layer3/)). Effects:

- Restarting or upgrading the agent briefly affects DNS for policed pods (**unverified** here, not measured).
- Names not resolved through kube-dns (hard-coded IPs, DNS-over-HTTPS) never match `toFQDNs`. They are denied, which is
  safe.
- Denied names get `REFUSED` (`tofqdns-dns-reject-response-code=refused`).

## cert-manager DNS-01 self-check

By default, cert-manager's propagation check queries the authoritative nameservers directly on port 53. That would need
`world:53` egress, which bypasses the DNS proxy. Likely fix: `--dns01-recursive-nameservers-only` plus kube-dns or a fixed
resolver allowed with `toCIDR`. **Unverified**, because DNS-01 was not exercised.

## Both ends are policed

Platform namespaces are policed too, so every flow between namespaces needs an egress rule at the source **and** an
ingress rule at the destination (see `platform-clients.yaml`).

## An empty ingress rule means the opposite in Kubernetes

In Cilium `ingress: [{}]` allows nothing. In a Kubernetes NetworkPolicy it allows everything. Do not convert between the
two formats mechanically.

## Charts ship their own policies

The argo-cd chart can create Kubernetes NetworkPolicies (`global.networkPolicy.create`), and ESO has
`networkPolicy.enabled`. Under allow-union they only add allows. Keep them off so the catalog policy is the single owner.

## Namespaces created outside Git are not labelled

Examples: `default`, `kube-public`, `kube-node-lease`, kind's `local-path-storage`, and anything an operator creates.
Conftest only sees rendered manifests, so these stay outside default-deny unless bootstrap labels them or an admission
policy rejects them ([open question](conclusions.md#unlabelled-namespaces)).

## Hubble noise and limits

- ICMPv6 RouterSolicitation drops (`Unsupported L3 protocol DROPPED`) show for every pod. This is noise, not policy.
- Hubble keeps only 4095 flows per node. Dumps of earlier phases lose older drops. Use Hubble relay or metrics for real
  debugging.
