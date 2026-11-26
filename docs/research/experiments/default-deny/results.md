# Default-deny experiment results

Run 4 (commit `6e2ee96`, `allow-localhost: policy`) ended with exit
code 0. `run.sh` was unmodified and its `EXIT` trap deleted the cluster. `out/cilium-config.txt` confirms
`allow-localhost=policy`, `enable-policy=default` and `kube-proxy-replacement=true`.

## Checks

`out/results.txt`. An expected `fail` means the traffic or the object must be refused.

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

## Webhooks need their rule

Checks `A5`, `A6`, `B1`, `B2` and `B4`. Phase A pods were all `1/1 Running` and the webhook rollouts succeeded, because
the kubelet-probe CNPs work on the probe ports. Yet:

```text
failed calling webhook "webhook.cert-manager.io": ... dial tcp 10.96.14.183:443: connect: connection timed out
failed calling webhook "validate.secretstore.external-secrets.io": ... context deadline exceeded
10.244.0.237:51502 (host) <> cert-manager/cert-manager-webhook-bf7f8b575-wst2t:10250 (ID:24216) Policy denied DROPPED (TCP Flags: SYN)
```

`10.244.0.237` is the node's `cilium_host` address (`Proxy Status: OK, ip 10.244.0.237`). The phase A `startupapicheck`
Job failed the same way and ended in `Error`.

The ESO result has no drop line: the Hubble dump runs before `A5` and `A6`. Its timeout is consistent with the
cert-manager drop, but does not prove the same cause ([re-run review](https://github.com/gsuquet/infra/pull/14#issuecomment-7004346056)).

With `fromEntities: kube-apiserver` on 10250, both webhooks work. Between `A6` and `B1`, `run.sh` applied the component
CNPs, restarted the Deployments and StatefulSets and recreated the `startupapicheck` Job. No other change opens `host` to
10250, so the rule is needed and sufficient here.

The rule is not shown to be narrower than `host`. From `out/identities.txt`, same in run 3:

```text
172.18.0.4/32   reserved:host
                reserved:kube-apiserver
ID 7            reserved:kube-apiserver
                reserved:remote-node
```

On **any node that runs kube-apiserver**, whatever the node count, the host identity (ID 1) carries the `kube-apiserver`
label. There the rule equals `fromEntities: host` on 10250, so a webhook pod on a control-plane node also accepts kubelet
and host-network traffic on that port ([re-run review](https://github.com/gsuquet/infra/pull/14#issuecomment-7004346056)). A kube-apiserver on another node gets identity 7, so
`fromEntities: [kube-apiserver]` should cover it without opening ingress to every `remote-node`. This is an inference
from the identity table, **not tested across nodes**.

## Argo CD compares after a late policy

Checks `A7` and `B0`. The `github-probe` Application was created at the end of phase A and stayed uncompared for 90 s.
Phase A Hubble lists 677 lines that mention `argocd-redis:6379`, of which 338 are `Policy denied DROPPED` and the rest
include `policy-verdict` lines ([re-run review](https://github.com/gsuquet/infra/pull/14#issuecomment-7004346056)). After `kubectl apply -f policies/components/`, it reached `OutOfSync` with no
`ComparisonError` inside the 300 s window, before any restart. The script records no exact time.

Limit: no `ComparisonError` was recorded when the policies landed, so this is a first comparison. Recovery from a
recorded error is not shown. cert-manager's `startupapicheck` does not recover: it is a Job that exhausted its retries
and had to be recreated.

## Metrics rules do not open the API

Checks `B15`, `B16` and `B17`. Monitoring reaches argocd-server 8083 and applicationset 8080, but not the argocd-server
API on 8080.

## Tenant flows

| Check | Flow | Outcome |
| --- | --- | --- |
| `C1` | gateway to the tenant-a server, before the tenant policy | denied |
| `C2` | tenant-a client to the tenant-a server | allowed |
| `C3` | gateway to the tenant-a server | allowed |
| `C4` | tenant-b to the tenant-a server | denied |
| `C5` | tenant-a to the world | denied |
| `C6` | tenant-a to argocd-server | denied |

The baseline also allows tenant DNS (`A1`) and kube-apiserver (`A2`).

## A clusterwide deny wins

Checks `D2` and `D3`. A CCNP `egressDeny` for `1.0.0.1/32` dropped the traffic even with the tenant's world allow in place
(`Policy denied by denylist DROPPED`). Deny policies take precedence over every allow, whether it comes from a CNP, a
CCNP or a Kubernetes NetworkPolicy ([Cilium docs: deny policies](https://docs.cilium.io/en/stable/security/policy/deny/)). Run 3 selected every policed namespace; run 4
selects tenants only.

## AppProject stops a tenant policy

Checks `D1`, `D5` and `D6`. A namespaced CNP with `toEntities: [world]` in `tenant-a` opened world egress despite the
clusterwide default-deny: allow rules are a union ([Cilium docs: rule basics](https://docs.cilium.io/en/stable/security/policy/intro/)). Delivered through Argo CD, the
same CNP is refused with `resource cilium.io:CiliumNetworkPolicy is not permitted in project tenant-a` and not created.
The `kind: "*"` wildcard under `group: cilium.io` works.

## Pod Security rejects host-network pods

Checks `D7` and `D8`. In `tenant-a`:
`pods "hostnet" is forbidden: violates PodSecurity "baseline:v1.37": host namespaces (hostNetwork=true)`. The same
manifest passes `--dry-run=server` in the unlabelled `exp-fixtures`. The run enforced `baseline` and only warned on
`restricted`. The platform uses `restricted` for tenants, which [ADR-0009](https://github.com/gsuquet/infra/blob/main/docs/adr/0009-tenant-onboarding-by-infra.md) says also rejects `hostNetwork`; that level was not
run.

## A pod label cannot forge a namespace label

Checks `D9`, `D10` and `D11`. The `tenant-b/spoof` pod carried
`io.cilium.k8s.namespace.labels.infra.gsuquet.com/role: gateway` as a pod label. Its Cilium identity
(`out/phaseD-spoof.txt`, abridged) has no `role` label, only the real namespace labels:

```text
k8s:app=spoof
k8s:io.cilium.k8s.namespace.labels.infra.gsuquet.com/network-policy=default-deny
…/tenant=tenant-b
k8s:io.kubernetes.pod.namespace=tenant-b
```

The identity also carries the `pod-security.*` labels of the namespace. With an egress allow from the harness, Hubble
shows the source allowed and the destination denied:

```text
tenant-b/spoof:50522 (ID:30782) -> argocd/argocd-server-…:8080 (ID:16829) policy-verdict:L3-Only EGRESS ALLOWED (TCP Flags: SYN)
tenant-b/spoof:50522 (ID:30782) <> argocd/argocd-server-…:8080 (ID:16829) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
tenant-b/spoof:39130 (ID:30782) -> tenant-a/server:8080 (ID:51301) policy-verdict:L3-Only EGRESS ALLOWED (TCP Flags: SYN)
tenant-b/spoof:39130 (ID:30782) <> tenant-a/server:8080 (ID:51301) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
```

The Cilium pages on Kubernetes constructs and identity-relevant labels do not document this filtering. It is observed
behavior of Cilium chart 1.20.5, not a documented guarantee: keep these three checks in the regression set.

## Restart noise

Phase B Hubble shows `argocd-server … <> 10.244.0.210:6379 (world) … EGRESS DENIED (TCP Flags: ACK, FIN)`: FINs of
connections to the old redis pod after the rollout restart, whose IP no longer maps to an endpoint. Not a policy gap.

## Run 3 caveat

Run 3 (commit `046f610`, default `allow-localhost`) passed 33/33, but its webhook checks passed with no allow: the host
identity reached the webhooks without any rule, so the webhook rule was not exercised. It does show two facts:

- Phase A pods were Ready while `argocd-server <> argocd-redis:6379 Policy denied DROPPED` (203 drops in about 2.5 min)
  and `github-probe` never compared.
- By default Cilium lets kubelet probes reach local pods:
  `10.244.0.30 (host) -> cert-manager-webhook:6080 policy-verdict:L3-Only INGRESS ALLOWED`.

Its full table is in the
[earlier write-up](https://github.com/gsuquet/infra/blob/cb2df16e5f5c112230795914fcb495f87863136d/docs/research/experiments/default-deny.md#run-3-commit-046f610-default-allow-localhost).

## What failed

- **Multi-node kind could not start.** `kind create cluster` with `kind-multinode.yaml` (control plane and worker) failed
  twice: the worker's kubelet never became healthy
  (`kubeadm join … kubelet-wait-bootstrap … context deadline exceeded`). The Colima VM is shared with another 2-node kind
  cluster, and `fs.inotify.max_user_instances` is 128. That is the usual cause in the kind known issues, but it was **not
  verified**. Memory is the other suspect: the memory gate, run on the same host afterwards, reports about 5.9 GiB free
  and refuses a 2-node cluster at 4 GiB per node.
- **Run 2 had two test bugs, now fixed.** The ACME ClusterIssuer referenced a missing Cloudflare secret, and cert-manager
  validates the solver before it registers the account: it was `InvalidSolver`, not a policy issue, and now uses an
  HTTP-01 stub. The AppProject check raced the fixture Helm repo: `no route to host`, because the Service had no backend
  yet and Argo CD only retries at the next reconcile. The script now waits until repo-server can fetch the index.
- **Not covered:** DNS-01 issuance (needs a real Cloudflare token), real secrets backends, Cilium Gateway API
  (`reserved:ingress`), cloudflared, host-network workloads as policy targets, GKE.
