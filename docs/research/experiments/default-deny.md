# Experiment: Cilium clusterwide default-deny

Status: **single-node verified.** Run 3 (commit `046f610`, Cilium default `allow-localhost`) passed 33/33 checks, but its webhook checks passed with no allow at all, so the webhook rule was untested. Run 4 (commit `6e2ee96`, `allow-localhost: policy`, executed 2026-11-19) passed **42/42 checks with 0 mismatches**: the webhooks are denied without the component CNP and work with it, the Argo CD metrics split holds, PSA rejects host-network tenant pods, a pod label cannot spoof a namespace label, and Argo CD recovers from a late policy without a restart (see [Run 4](#run-4-commit-6e2ee96-allow-localhost-policy)). Still open: cross-node kube-apiserver identity (multi-node), GKE, DNS-01.

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
| Cilium chart | 1.20.5 (`oci://quay.io/cilium/charts/cilium`), `kubeProxyReplacement: true`, tunnel mode, Hubble without relay, `extraConfig.allow-localhost: policy` from run 4 |
| Argo CD chart | argo-cd 10.18.1 (Argo CD v3.6.1), no dex, no notifications, chart NetworkPolicies off |
| cert-manager chart | v1.21.3 (`oci://quay.io/jetstack/charts/cert-manager`) |
| external-secrets chart | 2.15.0 |
| Probe images | `agnhost:2.53@sha256:99c6b4bb…`, `nginx:1.29.3-alpine@sha256:b3c656d5…` |

Run 4 used exactly these versions (`out/preflight.txt`: kind v0.33.0, kubectl v1.37.2, helm v4.3.2, jq 1.8.2, yq v4.53.6; chart `appVersion`s read with `helm show chart`: Cilium 1.20.5, Argo CD v3.6.1, external-secrets v2.15.0).

Host: Colima (4 CPUs, 7.7 GiB), with another 2-node kind cluster already running. Run 4 preflight: `memory: total=7920MiB used-by-kind=2014MiB free=5905MiB need=4096MiB (1 node(s) x 4GiB)`. `run.sh` refuses to start unless Docker `MemTotal` minus the memory used by existing kind nodes leaves `MIN_FREE_GIB_PER_NODE` (default 4 GiB) per new node, and prints the existing nodes.

All charts are installed the way the plan installs them: `helm template` piped into `kubectl apply --server-side`. Helm hooks are therefore plain resources, as in the rendered-manifests pattern.

The run has four phases:

1. **Phase A**: namespaces, the baseline CCNP, the kubelet-probe allows (`policies/kubelet-probes/`, run 4) and probe pods are applied first, then the three components. No component policies yet. This is what happens if the cluster layer lands before the component policies.
2. **Phase B**: the component policies are applied. Run 4 first checks that Argo CD recovers without a restart (B0), then restarts the components and runs the functional checks.
3. **Phase C**: the tenant profile.
4. **Phase D**: bypass attempts (a tenant CNP, a clusterwide deny, an Argo CD AppProject, and in run 4 a host-network pod and a pod label that spoofs a namespace label).

## Proposal: labels under `infra.gsuquet.com`

All of these are **namespace** labels. Namespaces are cluster-scoped, and the tenant AppProject allows no cluster-scoped resources, so tenants cannot set them. Pod labels are controlled by tenants and must never be used as a trust boundary across namespaces.

Cilium ignores a **pod** label that copies the namespace-label key (run 4, D9 to D11). The `tenant-b/spoof` pod carried `io.cilium.k8s.namespace.labels.infra.gsuquet.com/role: gateway` as a pod label, but its Cilium identity had no `role` label at all (only the real namespace labels `network-policy`, `tenant`, `pod-security.*`). With an egress allow from the harness, Hubble showed `EGRESS ALLOWED` at the source and `INGRESS DENIED` at argocd-server and tenant-a. The Cilium pages on Kubernetes constructs and identity-relevant labels do not document this filtering, so it is observed behaviour of Cilium 1.20.5, not a documented guarantee: keep D9 to D11 in the regression checks.

| Label | Values | Set on | Used by |
| --- | --- | --- | --- |
| `infra.gsuquet.com/network-policy` | `default-deny` (only value) | every namespace except `kube-system` | baseline CCNP selector; Conftest fails any namespace without it |
| `infra.gsuquet.com/role` | `gateway`, `monitoring` | platform namespaces that other namespaces must trust as peers | ingress rules (`fromEndpoints` on `io.cilium.k8s.namespace.labels.infra.gsuquet.com/role`) |
| `infra.gsuquet.com/tenant` | tenant name | tenant namespaces (from `gitops/tenants/<tenant>.yaml`) | selector for tenant-only hard denies (`egressDeny`); future allows between namespaces of the same tenant; reporting |
| `pod-security.kubernetes.io/enforce` (+ `-version`) | `baseline` (or `restricted`) | tenant namespaces | Pod Security Admission: rejects `hostNetwork`, `hostPort` and privileged pods, which Cilium policy cannot police (pitfall 2). Not under `infra.gsuquet.com`, it is the upstream Kubernetes key |

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
| argocd | ingress from `role=monitoring`, **one CNP per workload**: application-controller 8082, server 8083, repo-server 8084, applicationset-controller 8080 | metrics. Run 3 used one namespace-wide CNP for all four ports, which also opened argocd-server's API port 8080 to monitoring; review caught it. Run 4 adds B15 (server 8083), B16 (applicationset 8080) and the negative B17 (monitoring -> argocd-server API) |
| cert-manager | webhook pod ingress `fromEntities: kube-apiserver` on **10250** | admission webhook. The Service port is 443, but policy sees the pod port after the kube-proxy replacement translates it (run 4 phase A: `10.244.0.237:51502 (host) <> cert-manager-webhook…:10250 Policy denied DROPPED`) |
| cert-manager | controller egress `toFQDNs` `acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org`, `api.cloudflare.com` on 443 | ACME and DNS-01 through Cloudflare |
| cert-manager | ingress on 9402 from `role=monitoring` | metrics |
| external-secrets | webhook pod ingress `fromEntities: kube-apiserver` on **10250** | admission webhook |
| external-secrets | ingress on 8080 from `role=monitoring` | metrics |
| external-secrets | provider egress: **none** on kind (fake provider) | added per backend once the secrets-backend study settles, for example `toFQDNs: secretmanager.googleapis.com:443` |
| every component | ingress `fromEntities: host` on its **probe ports only** (argocd 8080/8082/8084, cert-manager 9403/6080, ESO 8081), never the webhook port 10250 | kubelet probes under `allow-localhost: policy` (`policies/kubelet-probes/`). Ports read from the rendered charts. Run 4 only |
| gateway, monitoring | egress to every `network-policy=default-deny` namespace | the source namespace is also policed, so every flow needs an egress allow at the source **and** an ingress allow at the destination |

The ESO cert-controller and cert-manager's cainjector and startupapicheck only talk to kube-apiserver. The baseline already covers that.

### Tenant layer (`policies/tenant/tenant-a.yaml`, rendered by infra per tenant)

- `tenant-intra-namespace`: ingress from and egress to `{}`.
- `tenant-gateway-ingress`: ingress from `role=gateway` namespaces and from the `ingress` entity.
- `tenant-kubelet-probes` (run 4): ingress `fromEntities: host` on any port. Infra does not know tenant probe ports, and tenants have no webhooks.
- Namespace labels: Pod Security Admission `enforce: baseline` (run 4, D7 and D8).

Nothing else: no world egress and no access to platform namespaces (C5 and C6).

### AppProject (`manifests/appproject.yaml`)

```yaml
namespaceResourceBlacklist:
  - {group: networking.k8s.io, kind: NetworkPolicy}
  - {group: cilium.io, kind: "*"}   # CNP, CiliumEnvoyConfig, CiliumLocalRedirectPolicy, ...
clusterResourceWhitelist: []
```

## Results

### Run 3 (commit `046f610`, default `allow-localhost`)

`out/results.txt`, abridged. A5 and A6 passing here is the flaw found in review: the host identity reached the webhooks without any rule, so the webhook allow was never exercised.

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
D2   fail      fail    OK       clusterwide egressDeny 1.0.0.1 beats the tenant allow (run 3: selected every policed namespace)
D3   pass      pass    OK       control: 1.1.1.1 still reachable through the tenant allow
D4   fail      fail    OK       after removing the bypass, world egress is denied again
D5   pass      pass    OK       Argo CD refuses the CNP: 'not permitted in project'
D6   fail      fail    OK       tenant-bypass CNP was not created in tenant-a
mismatches: 0
```

Key evidence:

- **Phase A: components look healthy while broken.** Every Argo CD, cert-manager and ESO pod was `1/1 Running`. Meanwhile Hubble showed `argocd-server <> argocd-redis:6379 Policy denied DROPPED` (203 drops in about 2.5 min), and the github-probe Application never compared (A7). Kubelet probes come from `reserved:host`, which Cilium allows to reach local pods by default (`10.244.0.30 (host) -> cert-manager-webhook:6080 policy-verdict:L3-Only INGRESS ALLOWED`). So readiness says nothing about policy.
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

### Run 4 (commit `6e2ee96`, `allow-localhost: policy`)

Executed 2026-11-19 on single-node kind, unmodified `run.sh` (no script bug hit), exit code 0, cluster deleted by the `EXIT` trap afterwards. `out/cilium-config.txt` confirms `allow-localhost=policy`, `enable-policy=default`, `kube-proxy-replacement=true`. `out/results.txt`:

```text
id   expected  actual  verdict  description
A1   pass      pass    OK       tenant-a DNS lookup through DNS proxy
A2   pass      pass    OK       tenant-a -> kube-apiserver (baseline)
A3   fail      fail    OK       tenant-a client -> tenant-a server (same namespace, denied)
A4   fail      fail    OK       tenant-a -> world (github.com:443)
A5   fail      fail    OK       cert-manager webhook without allow (allow-localhost=policy)
A6   fail      fail    OK       ESO webhook without allow (allow-localhost=policy)
A7   fail      fail    OK       argocd: compare github.com repo without component policies
B0   pass      pass    OK       argocd recovers without restart once its CNPs land (late policy)
B1   pass      pass    OK       cert-manager startupapicheck Job completes (webhook via kube-apiserver entity)
B2   pass      pass    OK       cert-manager: self-signed Certificate Ready
B3   pass      pass    OK       cert-manager: ACME ClusterIssuer registered with LE staging (toFQDNs)
B4   pass      pass    OK       ESO: ExternalSecret from SecretStore 'secrets' synced
B5   pass      pass    OK       argocd: repo-server compares github.com repo (toFQDNs github.com)
B6   pass      pass    OK       monitoring -> cert-manager metrics :9402
B7   pass      pass    OK       monitoring -> external-secrets metrics :8080
B8   pass      pass    OK       monitoring -> argocd repo-server metrics :8084
B9   pass      pass    OK       monitoring -> argocd application-controller metrics :8082
B15  pass      pass    OK       monitoring -> argocd-server metrics :8083
B16  pass      pass    OK       monitoring -> argocd applicationset metrics :8080
B17  fail      fail    OK       monitoring -> argocd-server API :8080 (metrics policy must not open it)
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
D2   fail      fail    OK       tenant-scoped clusterwide egressDeny 1.0.0.1 beats the tenant allow
D3   pass      pass    OK       control: 1.1.1.1 still reachable through the tenant allow
D4   fail      fail    OK       after removing the bypass, world egress is denied again
D5   pass      pass    OK       Argo CD refuses the CNP: 'not permitted in project'
D6   fail      fail    OK       tenant-bypass CNP was not created in tenant-a
D7   fail      fail    OK       hostNetwork pod in tenant-a rejected (PSA baseline)
D8   pass      pass    OK       control: same pod accepted in exp-fixtures (no PSA label)
D9   fail      fail    OK       spoofed pod (role=gateway pod label) -> argocd-server
D10  fail      fail    OK       spoofed pod (role=gateway pod label) -> tenant-a server
D11  pass      pass    OK       spoof flows denied at destination ingress, not source egress
mismatches: 0
```

Evidence for the checks run 4 added or flipped:

- **Webhooks fail for policy reasons, not readiness (A5, A6).** Phase A pods were all `1/1 Running`, webhook rollouts succeeded (kubelet-probe CNPs on probe ports work), yet:

  ```text
  failed calling webhook "webhook.cert-manager.io": ... dial tcp 10.96.14.183:443: connect: connection timed out
  failed calling webhook "validate.secretstore.external-secrets.io": ... context deadline exceeded
  10.244.0.237:51502 (host) <> cert-manager/cert-manager-webhook-bf7f8b575-wst2t:10250 (ID:24216) Policy denied DROPPED (TCP Flags: SYN)
  ```

  `10.244.0.237` is the node's `cilium_host` address (`Proxy Status: OK, ip 10.244.0.237`). The phase A `startupapicheck` Job failed the same way and ended in `Error`.
- **The `fromEntities: kube-apiserver` -> 10250 rule alone makes both webhooks work (B1, B2, B4).** Only the component CNPs were added between A5/A6 and B1. Caveat: on one node kube-apiserver's IP has the `host` identity (ID 1) **plus** the `kube-apiserver` label (`out/identities.txt`, same as run 3), so on one node this rule is equivalent to `fromEntities: host` on 10250. Run 4 proves the rule is needed and sufficient, not that it is narrower than `host`.
- **Argo CD recovers from a late policy without a restart (B0).** github-probe was created at the end of phase A and stayed uncompared for 90 s (A7; phase A Hubble: 677 `argocd-* <> argocd-redis:6379 Policy denied DROPPED` lines). After `kubectl apply -f policies/components/`, it reached `OutOfSync` with no `ComparisonError` inside the 300 s window, before any restart. File timestamps put B0 at under about 80 s; the script does not record the exact time. Limit: the Application had no `ComparisonError` yet when the policies landed, so recovery from an Application that had already recorded one is not shown. cert-manager's `startupapicheck` still needed recreating (it is a Job that exhausted its retries).
- **Metrics split (B15, B16, B17).** monitoring reaches argocd-server 8083 and applicationset 8080, but not argocd-server's API on 8080: the per-workload CNPs do not open the API port.
- **PSA (D7, D8).** `pods "hostnet" is forbidden: violates PodSecurity "baseline:v1.37": host namespaces (hostNetwork=true)` in tenant-a; the same manifest passes `--dry-run=server` in the unlabelled `exp-fixtures`.
- **Pod-label spoofing (D9 to D11).** Identity labels of `tenant-b/spoof` (`out/phaseD-spoof.txt`, abridged): `k8s:app=spoof`, `k8s:io.cilium.k8s.namespace.labels.infra.gsuquet.com/network-policy=default-deny`, `…/tenant=tenant-b`, `k8s:io.kubernetes.pod.namespace=tenant-b`. No `role=gateway`. Hubble:

  ```text
  tenant-b/spoof:50522 (ID:30782) -> argocd/argocd-server-…:8080 (ID:16829) policy-verdict:L3-Only EGRESS ALLOWED (TCP Flags: SYN)
  tenant-b/spoof:50522 (ID:30782) <> argocd/argocd-server-…:8080 (ID:16829) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
  tenant-b/spoof:39130 (ID:30782) -> tenant-a/server:8080 (ID:51301) policy-verdict:L3-Only EGRESS ALLOWED (TCP Flags: SYN)
  tenant-b/spoof:39130 (ID:30782) <> tenant-a/server:8080 (ID:51301) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
  ```

- **AppProject (D5).** `resource cilium.io:CiliumNetworkPolicy is not permitted in project tenant-a`, unchanged from run 3.
- **Restart noise.** Phase B Hubble shows `argocd-server … <> 10.244.0.210:6379 (world) … EGRESS DENIED (TCP Flags: ACK, FIN)`: FINs of connections to the old redis pod after the rollout restart, whose IP no longer maps to an endpoint. Not a policy gap.

## What failed

- **Multi-node kind could not start.** `kind create cluster` with `kind-multinode.yaml` (control plane + worker) failed twice: the worker's kubelet never became healthy (`kubeadm join … kubelet-wait-bootstrap … context deadline exceeded`). The Colima VM is shared with another 2-node kind cluster, and `fs.inotify.max_user_instances` is 128. That is the usual cause in the kind known issues, but **I did not verify it**. Memory contention is the other suspect: the new memory gate, run against the same host afterwards, reports about 5.9 GiB free after the other cluster and refuses a 2-node cluster at 4 GiB per node. Multi-node is no longer needed for the webhook rule (run 4 tests it on one node). It still matters for the identity of a kube-apiserver on another node (`remote-node` + `kube-apiserver`, identity 7), which stays an inference.
- **Run 2 had two test bugs, now fixed.** (1) The ACME ClusterIssuer referenced a missing Cloudflare secret, and cert-manager validates the solver before it registers the account, so it was `InvalidSolver`, not a policy issue. It now uses an HTTP-01 stub. (2) The AppProject check raced the fixture Helm repo: `no route to host`, because the Service had no backend yet, and Argo CD only retries at the next reconcile. The script now waits until repo-server can fetch the index.
- **Not covered:** DNS-01 issuance (needs a real Cloudflare token), real secrets backends, Cilium Gateway API (`reserved:ingress`), cloudflared, host-network workloads as policy targets (run 4 only checks that PSA rejects them in tenant namespaces), GKE.

## Pitfalls

1. **Host to local pod traffic is allowed by default.** The Cilium layer-3 page states it: "Kubernetes will automatically allow all communication from the local host of all local endpoints", and the agent option `--allow-localhost=policy` turns it off ([Cilium docs: layer 3, entities](https://docs.cilium.io/en/stable/security/policy/layer3/)). With the default, a one-node cluster hides webhook rules, because kube-apiserver carries the host identity (run 3, A5 and A6). Run 4 sets `extraConfig.allow-localhost: policy`, and the webhooks are then denied until their CNP lands (run 4, A5 and A6). Every policed pod then needs an explicit `fromEntities: host` allow on its kubelet probe ports, and that allow must not cover webhook ports. The probe ports in `policies/kubelet-probes/` were correct in run 4 (every pod Ready in phase A; argocd-redis and applicationset-controller needed no host allow). On a production cluster the same switch also stops host-network pods on a node from reaching every local pod. Whether to keep it beyond the experiment is an open question.
2. **Host-network pods are not Cilium endpoints.** CNPs and CCNPs do not select them, for example Talos static control-plane pods or a webhook with `hostNetwork: true`. Policing them needs Cilium host policies (host firewall), which is a separate feature with its own known issues ([Cilium docs: host policies](https://docs.cilium.io/en/stable/security/policy/host/)). As sources, they appear as `host` or `remote-node`. A tenant Deployment with `hostNetwork: true` would escape default-deny entirely, and the AppProject cannot stop it (it filters kinds, not pod specs). Tenant namespaces therefore need Pod Security Admission `baseline` or stricter, which rejects `hostNetwork`, `hostPort` and privileged pods (run 4, D7).
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

- **The design holds on single-node kind (run 4, 42/42).** A label-selected CCNP default-deny, plus a per-component and a per-tenant CNP allow profile, gave the expected isolation for intra-namespace, Git, ACME, metrics, gateway and tenant flows, and the `kube-apiserver` -> 10250 webhook rule is both needed and sufficient. On one node that rule cannot be told apart from `fromEntities: host`; its narrower meaning across nodes is still an inference.
- **Each component ships its policy.** `gitops/components/<name>/` should include its CNPs, kubelet-probe allows included, in the same rendered directory. If the baseline lands before a component's policy, the component breaks while its pods stay Ready (phase A). Argo CD recovered by itself once its late CNPs landed (run 4, B0), for an Application that had not yet recorded a `ComparisonError`. cert-manager's `startupapicheck` Job does not recover: it exhausted its retries in phase A and had to be recreated. The order "component CNPs before the baseline" was not tested. Shipping CNPs in the same or an earlier sync wave is a recommendation, not a measured requirement.
- **Bootstrap boundary.** Terraform applies `rendered/argocd`. If the baseline CCNP is applied before Argo CD's own CNPs, Argo CD cannot reach redis or GitHub and cannot adopt anything. Ship the Argo CD CNPs inside `rendered/argocd`, and give the baseline CCNP its own cluster-layer component (for example `network-policy`) that Argo CD applies after it is healthy. **This adds a component to the settled baseline list** (see open questions).
- **Tenants are blocked by Argo CD and Pod Security Admission, not by Cilium.** Cilium cannot stop an allow it is given, so the AppProject `namespaceResourceBlacklist` (`networking.k8s.io/NetworkPolicy`, `cilium.io/*`) is the control for policy objects, and it works (D5, D6). It does not cover pod specs: a `hostNetwork: true` pod is not a Cilium endpoint and escapes every policy. Tenant onboarding must also label tenant namespaces with `pod-security.kubernetes.io/enforce: baseline` (or `restricted`), and Conftest must fail a tenant namespace without it (run 4, D7 and D8: PSA baseline rejects the `hostNetwork` pod). Pod labels cannot forge namespace labels (run 4, D9 to D11). Tenant Kubernetes RBAC must deny the same kinds if tenants ever get `kubectl` access.
- **Use clusterwide `egressDeny` for hard limits, scoped to tenant namespaces.** Tenants cannot override a deny, and neither can anyone else (D2). Select on `infra.gsuquet.com/tenant` existing, never on every policed namespace. On GKE, pods get Workload Identity tokens from the GKE metadata server at `169.254.169.254`. ESO needs that if the secrets backend becomes GCP Secret Manager, and a blanket deny could not be lifted for it afterwards. A tenant that itself needs Workload Identity would need its own exception design. Candidates: the metadata IP and maybe the node CIDRs, for tenants only.
- **Readiness does not prove policy.** The deferred kind e2e CI job should reuse this script's functional checks (webhook call, Git compare, metrics scrape).
- **GKE needs its own run.** GKE Dataplane V2 accepts `CiliumClusterwideNetworkPolicy` ([GKE docs: Dataplane V2](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2)). Cilium warns that `kube-apiserver` may not work for ingress on GKE ([Cilium docs: layer 3](https://docs.cilium.io/en/stable/security/policy/layer3/)). Whether GKE supports `toFQDNs`, DNS L7 rules and `enableDefaultDeny` is **unverified**. Expect a GKE variant for webhook ingress (control-plane CIDR) and FQDN egress.

## Open questions for the owner

1. **Baseline kube-apiserver egress.** Should every pod get it, tenants included? Most tenant apps never call the API. A tenant-only profile without it would shrink the attack surface. The settled plan gives it to everyone.
2. **Unlabelled namespaces.** Add a `ValidatingAdmissionPolicy` that rejects namespaces without `infra.gsuquet.com/network-policy`, so namespaces outside Git are covered too, or label them from bootstrap?
3. **Multi-node.** Run 4 passed on one node. The remaining gap is the cross-node `kube-apiserver` identity (identity 7, `kube-apiserver` + `remote-node`), where `fromEntities: kube-apiserver` should stop being equivalent to `host`. Run `KIND_CONFIG=kind-multinode.yaml run.sh` on a host with 8 GiB free for kind, or check it on the first Talos Pi cluster.
4. **`network-policy` as a baseline component.** The bootstrap order needs the baseline CCNP in its own cluster-layer component. That adds a sixth baseline component to the settled list (gateway-api-crds, cilium, argocd, cert-manager, external-secrets). Accept, or fold the CCNP into the `cilium` component (which GKE skips, so GKE would need it elsewhere)?
5. **`allow-localhost: policy` beyond the experiment.** Keep it on kind and Talos? It closes host-network to local pod traffic, but every component must then ship correct kubelet-probe allows, and a wrong port shows up as a NotReady pod. Whether GKE Dataplane V2 exposes the option is **unverified**.
6. **Pod Security Admission level for tenants.** `baseline` is enough to block host-network pods. `restricted` is stricter but breaks images that run as root. The experiment enforces `baseline` and warns on `restricted`.
7. **Metadata IP and Workload Identity.** Tie the tenant-only metadata deny to the secrets-backend study: if GCP Secret Manager wins, ESO keeps metadata access, and tenants that need GCP APIs need a design of their own.
8. **Value of the policy label.** Keep only `default-deny`, or reserve another value (for example `audit`) for a migration period? Cilium's audit mode is per agent or per endpoint, not per namespace label, so it would need more design.
