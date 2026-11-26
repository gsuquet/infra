# Default-deny experiment policies

The labels and allow profiles that [run 4](results.md) applied. The exact YAML is in
[`experiments/default-deny/policies/`](../../../../experiments/default-deny/policies/). Where the platform differs, see
[what was run and what the platform uses](../default-deny.md#what-was-run-and-what-the-platform-uses).

## Labels

All are **namespace** labels. Namespaces are cluster-scoped and the tenant AppProject allows no cluster-scoped resource,
so tenants cannot set them. Tenants control pod labels: never use one as a trust boundary across namespaces.

| Label in the run | Values | Set on | Used by |
| --- | --- | --- | --- |
| `infra.gsuquet.com/network-policy` (platform: `network.infra.gsuquet.com/policy`) | `default-deny` (only value) | every namespace the run created, except the `exp-fixtures` test fixture | baseline CCNP selector; on the platform, Conftest fails any rendered namespace without its label, except `kube-system` |
| `infra.gsuquet.com/role` | `gateway`, `monitoring` | platform namespaces that other namespaces must trust as peers | ingress rules (`fromEndpoints` on `io.cilium.k8s.namespace.labels.infra.gsuquet.com/role`) |
| `infra.gsuquet.com/tenant` | tenant name | tenant namespaces (from `gitops/tenants/<tenant>.yaml`) | selector for tenant-only hard denies (`egressDeny`); future allows between namespaces of the same tenant; reporting |
| `pod-security.kubernetes.io/enforce` (and `-version`) | `baseline` in the run | tenant namespaces in the run | Pod Security Admission: rejects `hostNetwork`, `hostPort` and privileged pods, which Cilium policy cannot police. Upstream Kubernetes key |

In a Cilium selector, the namespace label appears as `k8s:io.cilium.k8s.namespace.labels.<key>`
([Cilium docs: Kubernetes constructs](https://docs.cilium.io/en/stable/security/policy/kubernetes/)).

## Cluster layer

From `policies/baseline/default-deny.yaml`:

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: baseline-default-deny
spec:
  endpointSelector:
    matchLabels:
      # Key of the run. The platform key is network.infra.gsuquet.com/policy.
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

## Component layer

The run keeps one file per component. On the platform, the `network-policy` component hosts the component allows.
Kubelet-probe allows are not in RFC 0010 or RFC 0014 ([PR 18](https://github.com/gsuquet/infra/pull/18)) and depend on an
[open question](conclusions.md#localhost-policy-beyond-the-experiment).

| Component | Policy | Why |
| --- | --- | --- |
| argocd | ingress from and egress to `{}` (same namespace) | server, application-controller, applicationset and repo-server all need redis (6379) and repo-server (8081) |
| argocd | repo-server egress `toFQDNs: github.com` on 443 and 22 | Git fetch of rendered manifests. Other hosts are denied (check `B13`: `repo-server -> 172.65.251.78:443 (world) Policy denied`) |
| argocd | server ingress on 8080 from `role=gateway` namespaces and from the `ingress` entity | UI and API through the gateway. `ingress` is the identity of Cilium's own Gateway API Envoy (not exercised here) |
| argocd | ingress from `role=monitoring`, **one CNP per workload**: application-controller 8082, server 8083, repo-server 8084, applicationset-controller 8080 | metrics. One namespace-wide CNP for all four ports (run 3) also opened argocd-server's API port 8080 to monitoring |
| cert-manager | webhook pod ingress `fromEntities: kube-apiserver` on **10250** | admission webhook. The Service port is 443, but policy sees the pod port after the kube-proxy replacement translates it |
| cert-manager | controller egress `toFQDNs` `acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org`, `api.cloudflare.com` on 443 | ACME, and DNS-01 through Cloudflare |
| cert-manager | ingress on 9402 from `role=monitoring` | metrics |
| external-secrets | webhook pod ingress `fromEntities: kube-apiserver` on **10250** | admission webhook |
| external-secrets | ingress on 8080 from `role=monitoring` | metrics |
| external-secrets | provider egress: **none** on kind (fake provider) | added per backend once the secrets-backend study settles, for example `toFQDNs: secretmanager.googleapis.com:443` |
| every component | ingress `fromEntities: host` on its **probe ports only** (argocd 8080/8082/8084, cert-manager 9403/6080, ESO 8081), never the webhook port 10250 | kubelet probes under `allow-localhost: policy` (`policies/kubelet-probes/`). Ports read from the rendered charts |
| gateway, monitoring | egress to every `network-policy=default-deny` namespace | the source namespace is [also policed](pitfalls.md#both-ends-are-policed) |

The ESO cert-controller and cert-manager's cainjector and startupapicheck only talk to kube-apiserver, which the baseline
already covers.

## Tenant layer

From `policies/tenant/tenant-a.yaml`, which stands for what infra renders per tenant:

| Policy | Allows |
| --- | --- |
| `tenant-intra-namespace` | ingress from and egress to `{}` |
| `tenant-gateway-ingress` | ingress from `role=gateway` namespaces and from the `ingress` entity |
| `tenant-kubelet-probes` | ingress `fromEntities: host` on any port: infra does not know tenant probe ports, and tenants have no webhooks |

Nothing else: no world egress and no access to platform namespaces (checks `C5` and `C6`).

## AppProject

From `manifests/appproject.yaml`. The `cilium.io/*` entry is wider than the one of [ADR-0009](https://github.com/gsuquet/infra/blob/main/docs/adr/0009-tenant-onboarding-by-infra.md)
([proposed amendment](conclusions.md#proposed-amendments)).

```yaml
namespaceResourceBlacklist:
  - {group: networking.k8s.io, kind: NetworkPolicy}
  - {group: cilium.io, kind: "*"}   # CNP, CiliumEnvoyConfig, CiliumLocalRedirectPolicy, ...
clusterResourceWhitelist: []
```
