# Experiment: Cilium clusterwide default-deny

Status: done on single-node kind (33/33 checks as expected). The multi-node variant could not run on the test machine, so the cross-node webhook path is **unverified** (see [What failed](#what-failed)).

Scripts: [`experiments/default-deny/`](../../../experiments/default-deny/). Run `experiments/default-deny/run.sh`: it creates the kind cluster `exp-default-deny`, runs every check, writes evidence to `experiments/default-deny/out/` (git-ignored) and always deletes the cluster.

## Goal

Check the settled network-policy design before it goes into the component catalog:

- A `CiliumClusterwideNetworkPolicy` (CCNP) puts every namespace that has a policy label into default-deny. `kube-system` is excluded.
- Baseline allows for kube-dns and kube-apiserver.
- Find the smallest allow profile that keeps Argo CD, cert-manager and external-secrets (ESO) working: webhooks, Git egress, ACME egress, provider egress and metrics.
- Tenant namespace: deny everything, then allow traffic inside the namespace and from the gateway.
- Find out whether a tenant can bypass the default-deny with its own namespaced policy, and what stops it.

## Setup

| Item | Version |
| --- | --- |
| kind | 0.33.0, node `kindest/node:v1.37.0@sha256:a1ed56cf…` (Kubernetes 1.37.0) |
| kubectl / helm / jq / yq | 1.37.2 / 4.3.2 / 1.8.2 / 4.53.6 (`experiments/default-deny/mise.toml` + `mise.lock`) |
| Cilium chart | 1.20.5 (`oci://quay.io/cilium/charts/cilium`), `kubeProxyReplacement: true`, tunnel mode, Hubble without relay |
| Argo CD chart | argo-cd 10.18.1 (Argo CD v3.6.1), no dex, no notifications, chart NetworkPolicies off |
| cert-manager chart | v1.21.3 (`oci://quay.io/jetstack/charts/cert-manager`) |
| external-secrets chart | 2.15.0 |
| Probe images | `agnhost:2.53@sha256:99c6b4bb…`, `nginx:1.29.3-alpine@sha256:b3c656d5…` |

Host: Colima (4 CPUs, 7.7 GiB), with another 2-node kind cluster already running.

All charts are installed the way the plan installs them: `helm template` piped into `kubectl apply --server-side`. Helm hooks are therefore plain resources, as in the rendered-manifests pattern.

The run has four phases:

1. **Phase A**: namespaces, the baseline CCNP and probe pods are applied first, then the three components. No component policies yet. This is what happens if the cluster layer lands before the component policies.
2. **Phase B**: the component policies are applied, the components restarted, then functional checks run.
3. **Phase C**: the tenant profile.
4. **Phase D**: bypass attempts (a tenant CNP, a clusterwide deny, and an Argo CD AppProject).

## Proposal: labels under `infra.gsuquet.com`

All of these are **namespace** labels. Namespaces are cluster-scoped, and the tenant AppProject allows no cluster-scoped resources, so tenants cannot set them. Pod labels are controlled by tenants and must never be used as a trust boundary across namespaces.

| Label | Values | Set on | Used by |
| --- | --- | --- | --- |
| `infra.gsuquet.com/network-policy` | `default-deny` (only value) | every namespace except `kube-system` | baseline CCNP selector; Conftest fails any namespace without it |
| `infra.gsuquet.com/role` | `gateway`, `monitoring` | platform namespaces that other namespaces must trust as peers | ingress rules (`fromEndpoints` on `io.cilium.k8s.namespace.labels.infra.gsuquet.com/role`) |
| `infra.gsuquet.com/tenant` | tenant name | tenant namespaces (from `gitops/tenants/<tenant>.yaml`) | future allows between namespaces of the same tenant; reporting |

In a Cilium selector, the namespace label appears as `k8s:io.cilium.k8s.namespace.labels.<key>` ([Cilium docs: Kubernetes constructs](https://docs.cilium.io/en/stable/security/policy/kubernetes/)).

## Policies

The exact YAML is in `experiments/default-deny/policies/`. Summary:

### Cluster layer (`policies/baseline/default-deny.yaml`)

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: baseline-default-deny
spec:
  endpointSelector:
    matchLabels:
      k8s:io.cilium.k8s.namespace.labels.infra.gsuquet.com/network-policy: default-deny
    matchExpressions:
      - key: k8s:io.kubernetes.pod.namespace
        operator: NotIn
        values: [kube-system]
  enableDefaultDeny: {ingress: true, egress: true}
  ingress:
    - {}          # no peer = allows nothing, but switches ingress to default-deny
  egress:
    - toEndpoints:
        - matchLabels: {k8s:io.kubernetes.pod.namespace: kube-system, k8s:k8s-app: kube-dns}
      toPorts:
        - ports: [{port: "53", protocol: UDP}, {port: "53", protocol: TCP}]
          rules: {dns: [{matchPattern: "*"}]}   # DNS proxy, required by toFQDNs
    - toEntities: [kube-apiserver]
```

### Component layer (one file per component, shipped with the component)

| Component | Policy | Why |
| --- | --- | --- |
| argocd | ingress from and egress to `{}` (same namespace) | server, application-controller, applicationset and repo-server all need redis (6379) and repo-server (8081). Phase A shows `argocd-server -> argocd-redis:6379 Policy denied DROPPED` |
| argocd | repo-server egress `toFQDNs: github.com` on 443 and 22 | Git fetch of rendered manifests. Other hosts are denied (B13: `repo-server -> 172.65.251.78:443 (world) Policy denied`) |
| argocd | server ingress on 8080 from `role=gateway` namespaces and from the `ingress` entity | UI/API through the gateway. `ingress` is the identity of Cilium's own Gateway API Envoy (not exercised here) |
| argocd | ingress on 8082/8083/8084/8080 from `role=monitoring` | metrics for controller, server, repo-server and applicationset |
| cert-manager | webhook pod ingress `fromEntities: kube-apiserver` on **10250** | admission webhook. The Service port is 443, but policy sees the pod port after the kube-proxy replacement translates it |
| cert-manager | controller egress `toFQDNs` `acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org`, `api.cloudflare.com` on 443 | ACME and DNS-01 through Cloudflare |
| cert-manager | ingress on 9402 from `role=monitoring` | metrics |
| external-secrets | webhook pod ingress `fromEntities: kube-apiserver` on **10250** | admission webhook |
| external-secrets | ingress on 8080 from `role=monitoring` | metrics |
| external-secrets | provider egress: **none** on kind (fake provider) | added per backend once the secrets-backend study settles, for example `toFQDNs: secretmanager.googleapis.com:443` |
| gateway, monitoring | egress to every `network-policy=default-deny` namespace | the source namespace is also policed, so every flow needs an egress allow at the source **and** an ingress allow at the destination |

The ESO cert-controller and cert-manager's cainjector and startupapicheck only talk to kube-apiserver. The baseline already covers that.

### Tenant layer (`policies/tenant/tenant-a.yaml`, rendered by infra per tenant)

- `tenant-intra-namespace`: ingress from and egress to `{}`.
- `tenant-gateway-ingress`: ingress from `role=gateway` namespaces and from the `ingress` entity.

Nothing else: no world egress and no access to platform namespaces (C5 and C6).

### AppProject (`manifests/appproject.yaml`)

```yaml
namespaceResourceBlacklist:
  - {group: networking.k8s.io, kind: NetworkPolicy}
  - {group: cilium.io, kind: "*"}   # CNP, CiliumEnvoyConfig, CiliumLocalRedirectPolicy, ...
clusterResourceWhitelist: []
```

## Results

Final run (`out/results.txt`, abridged):

```text
id   expected  actual  verdict  description
A1   pass      pass    OK       tenant-a DNS lookup through DNS proxy
A2   pass      pass    OK       tenant-a -> kube-apiserver (baseline)
A3   fail      fail    OK       tenant-a client -> tenant-a server (same namespace, denied)
A4   fail      fail    OK       tenant-a -> world (github.com:443)
A5   pass      pass    OK       cert-manager webhook without allow (1 node(s))
A6   pass      pass    OK       ESO webhook without allow (1 node(s))
A7   fail      fail    OK       argocd: compare github.com repo without component policies
B1   pass      pass    OK       cert-manager startupapicheck Job completes (webhook via kube-apiserver entity)
B2   pass      pass    OK       cert-manager: self-signed Certificate Ready
B3   pass      pass    OK       cert-manager: ACME ClusterIssuer registered with LE staging (toFQDNs)
B4   pass      pass    OK       ESO: ExternalSecret from SecretStore 'secrets' synced
B5   pass      pass    OK       argocd: repo-server compares github.com repo (toFQDNs github.com)
B6-B9 pass     pass    OK       monitoring -> cert-manager 9402, ESO 8080, argocd 8084 and 8082 metrics
B10  fail      fail    OK       tenant-b -> cert-manager metrics (not a monitoring namespace)
B11  pass      pass    OK       gateway -> argocd-server :80
B12  fail      fail    OK       tenant-b -> argocd-server :80
B13  fail      fail    OK       argocd repo-server egress to a non-allowed FQDN (gitlab.com)
B14  pass      pass    OK       argocd repo-server egress to github.com
C1   fail      fail    OK       gateway -> tenant-a server before tenant policy
C2   pass      pass    OK       tenant-a client -> tenant-a server (intra-namespace)
C3   pass      pass    OK       gateway -> tenant-a server
C4   fail      fail    OK       tenant-b -> tenant-a server
C5   fail      fail    OK       tenant-a -> world still denied
C6   fail      fail    OK       tenant-a -> argocd-server (platform namespace)
D1   pass      pass    OK       tenant-a CNP 'toEntities: world' opens world egress (union bypass works)
D2   fail      fail    OK       clusterwide egressDeny 1.0.0.1 beats the tenant allow
D3   pass      pass    OK       control: 1.1.1.1 still reachable through the tenant allow
D4   fail      fail    OK       after removing the bypass, world egress is denied again
D5   pass      pass    OK       Argo CD refuses the CNP: 'not permitted in project'
D6   fail      fail    OK       tenant-bypass CNP was not created in tenant-a
mismatches: 0
```

Key evidence:

- **Phase A: components look healthy while broken.** Every Argo CD, cert-manager and ESO pod was `1/1 Running`. Meanwhile Hubble showed `argocd-server <> argocd-redis:6379 Policy denied DROPPED` (203 drops in about 2.5 min), and the github-probe Application never compared (A7). Kubelet probes come from `reserved:host`, which is always allowed to reach local pods (`10.244.0.30 (host) -> cert-manager-webhook:6080 policy-verdict:L3-Only INGRESS ALLOWED`). So readiness says nothing about policy.
- **The tenant bypass works (D1).** A namespaced `CiliumNetworkPolicy` with `toEntities: [world]` in `tenant-a` opened world egress despite the clusterwide default-deny. Allow rules are a union ([Cilium docs: rule basics](https://docs.cilium.io/en/stable/security/policy/intro/)).
- **The AppProject stops it (D5).** Argo CD reported `resource cilium.io:CiliumNetworkPolicy is not permitted in project tenant-a` and did not create the CNP (D6). The `kind: "*"` wildcard under `group: cilium.io` works.
- **Deny wins (D2).** A CCNP `egressDeny` for `1.0.0.1/32` dropped the traffic even with the tenant's world allow in place (`Policy denied by denylist DROPPED`). Deny policies take precedence over every allow, whether it comes from a CNP, a CCNP or a Kubernetes NetworkPolicy ([Cilium docs: deny policies](https://docs.cilium.io/en/stable/security/policy/deny/)).
- **Identities seen by the agent** (`out/identities.txt`):

  ```text
  172.18.0.4/32   reserved:host
                  reserved:kube-apiserver
  ID 7            reserved:kube-apiserver
                  reserved:remote-node
  ```

  On one node, kube-apiserver's IP carries the `host` identity plus the `kube-apiserver` label. A kube-apiserver on another node gets identity 7 (`kube-apiserver` + `remote-node`). So `fromEntities: [kube-apiserver]` should cover both cases without opening ingress to every `remote-node`. This is an inference from the identity table and is **not tested across nodes**.

## What failed

- **Multi-node kind could not start.** `kind create cluster` with `kind-multinode.yaml` (control plane + worker) failed twice: the worker's kubelet never became healthy (`kubeadm join … kubelet-wait-bootstrap … context deadline exceeded`). The Colima VM is shared with another 2-node kind cluster, and `fs.inotify.max_user_instances` is 128. That is the usual cause in the kind known issues, but **I did not verify it**: I did not change the VM sysctl because the VM is shared. Because of this, the webhook checks A5 and A6 pass *without* any allow on one node (host identity). The cross-node path, where `fromEntities: kube-apiserver` is required, is **unverified**. Re-run with `KIND_CONFIG=kind-multinode.yaml experiments/default-deny/run.sh` on a host with headroom, or check it on the first Talos Pi cluster.
- **Run 2 had two test bugs, now fixed.** (1) The ACME ClusterIssuer referenced a missing Cloudflare secret, and cert-manager validates the solver before it registers the account, so it was `InvalidSolver`, not a policy issue. It now uses an HTTP-01 stub. (2) The AppProject check raced the fixture Helm repo: `no route to host`, because the Service had no backend yet, and Argo CD only retries at the next reconcile. The script now waits until repo-server can fetch the index.
- **Not covered:** DNS-01 issuance (needs a real Cloudflare token), real secrets backends, Cilium Gateway API (`reserved:ingress`), cloudflared, host-network workloads, GKE.

## Pitfalls

1. **Single-node clusters hide webhook rules.** Host to local pod traffic is always allowed. On one node the kube-apiserver (host network) reaches webhooks with no rule (A5 and A6). Do not take a webhook profile from a one-node kind run as proof: keep the explicit `fromEntities: kube-apiserver` rule. The always-allow behavior was observed here. I could not find it stated on the Cilium policy pages I read (**unverified** in the docs).
2. **Host-network pods are not Cilium endpoints.** CNPs and CCNPs do not select them, for example Talos static control-plane pods or a webhook with `hostNetwork: true`. Policing them needs Cilium host policies (host firewall), which is a separate feature with its own known issues ([Cilium docs: host policies](https://docs.cilium.io/en/stable/security/policy/host/)). As sources, they appear as `host` or `remote-node`.
3. **`reserved:remote-node` is broad.** Allowing `remote-node` lets in every node and every host-network pod on other nodes. Prefer `kube-apiserver`, which is a label on top of `remote-node` (identity 7). North-south traffic forwarded between nodes can also arrive as `remote-node` in native routing, and as `world` in tunnel mode ([Cilium docs: caveats](https://docs.cilium.io/en/stable/security/policy/caveats/)). Cloudflare Tunnel avoids this, because cloudflared is an in-cluster client that enters through the gateway namespace.
4. **DNS proxy.** The baseline L7 DNS rule sends every lookup from a policed pod through the Cilium agent's DNS proxy. That is a requirement for `toFQDNs` ([Cilium docs: layer 3, DNS-based](https://docs.cilium.io/en/stable/security/policy/layer3/)). Effects:
   - Restarting or upgrading the agent briefly affects DNS for policed pods (**unverified** here, not measured).
   - Names not resolved through kube-dns (hard-coded IPs, DNS-over-HTTPS) never match `toFQDNs`. They are denied, which is safe.
   - Denied names get `REFUSED` (`tofqdns-dns-reject-response-code=refused`).
5. **cert-manager DNS-01 self-check.** By default, cert-manager's propagation check queries the authoritative nameservers directly on port 53. That would need `world:53` egress, which bypasses the DNS proxy. Likely fix: `--dns01-recursive-nameservers-only` plus kube-dns or a fixed resolver allowed with `toCIDR`. **Unverified**, because DNS-01 was not exercised.
6. **Both ends are policed.** Platform namespaces are policed too, so every flow between namespaces needs an egress rule at the source and an ingress rule at the destination (see `platform-clients.yaml`).
7. **`ingress: [{}]` means the opposite in Kubernetes NetworkPolicy.** In Cilium it allows nothing. In a Kubernetes NetworkPolicy it allows everything. Do not convert between the two formats mechanically.
8. **Charts ship their own policies.** The argo-cd chart can create Kubernetes NetworkPolicies (`global.networkPolicy.create`), and ESO has `networkPolicy.enabled`. Under allow-union they only add allows. Keep them off so the catalog policy is the single owner.
9. **Namespaces created outside Git are not labelled.** Examples: `default`, `kube-public`, `kube-node-lease`, kind's `local-path-storage`, and anything an operator creates. Conftest only sees rendered manifests. These namespaces stay outside default-deny unless bootstrap labels them or an admission policy rejects unlabelled namespaces (see open questions).
10. **ICMPv6 RouterSolicitation drops** (`Unsupported L3 protocol DROPPED`) show in Hubble for every pod. This is noise, not policy.
11. **Hubble keeps only 4095 flows per node.** Dumps of earlier phases lose older drops. Use Hubble relay or metrics for real debugging.

## Conclusions for the plan

- **The design holds.** A label-selected CCNP default-deny, plus a per-component and a per-tenant CNP allow profile, gave the expected isolation for every check.
- **Each component ships its policy.** `gitops/components/<name>/` should include its CNPs in the same rendered directory, applied in the **same or an earlier sync wave** than the workloads. If the baseline lands before a component's policy, the component breaks silently (phase A).
- **Bootstrap boundary.** Terraform applies `rendered/argocd`. If the baseline CCNP is applied before Argo CD's own CNPs, Argo CD cannot reach redis or GitHub and cannot adopt anything. Ship the Argo CD CNPs inside `rendered/argocd`, and give the baseline CCNP its own cluster-layer component (for example `network-policy`) that Argo CD applies after it is healthy.
- **Tenants are blocked by Argo CD, not by Cilium.** Cilium cannot stop an allow it is given, so the AppProject `namespaceResourceBlacklist` (`networking.k8s.io/NetworkPolicy`, `cilium.io/*`) is the control, and it works. Tenant Kubernetes RBAC must deny the same kinds if tenants ever get `kubectl` access.
- **Use clusterwide `egressDeny` for hard limits.** Tenants cannot override it. Candidates are the cloud metadata IP `169.254.169.254/32` on GKE and maybe the node CIDRs.
- **Readiness does not prove policy.** The deferred kind e2e CI job should reuse this script's functional checks (webhook call, Git compare, metrics scrape).
- **GKE needs its own run.** GKE Dataplane V2 accepts `CiliumClusterwideNetworkPolicy` ([GKE docs: Dataplane V2](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2)). Cilium warns that `kube-apiserver` may not work for ingress on GKE ([Cilium docs: layer 3](https://docs.cilium.io/en/stable/security/policy/layer3/)). Whether GKE supports `toFQDNs`, DNS L7 rules and `enableDefaultDeny` is **unverified**. Expect a GKE variant for webhook ingress (control-plane CIDR) and FQDN egress.

## Open questions for the owner

1. **Baseline kube-apiserver egress.** Should every pod get it, tenants included? Most tenant apps never call the API. A tenant-only profile without it would shrink the attack surface. The settled plan gives it to everyone.
2. **Unlabelled namespaces.** Add a `ValidatingAdmissionPolicy` that rejects namespaces without `infra.gsuquet.com/network-policy`, so namespaces outside Git are covered too, or label them from bootstrap?
3. **Re-run multi-node.** Who re-runs the multi-node variant, and on which host: a dev machine with headroom, or the first Talos Pi cluster? It is the last check before the webhook profile is final.
4. **Value of the policy label.** Keep only `default-deny`, or reserve another value (for example `audit`) for a migration period? Cilium's audit mode is per agent or per endpoint, not per namespace label, so it would need more design.
