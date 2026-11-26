# Cilium, Gateway API and CoreDNS on Talos

<!-- readability: allow-code L2 -->

Machine config, Cilium values and CRDs that Talos needs. **(unverified)** is defined in
[current state](0025-talos-raspberry-pi-rollout.md#current-state). Evidence for [RFC 0025](../rfc/0025-talos-raspberry-pi.md); the RFC holds the decision.

## Cilium, Gateway API and CoreDNS

Machine config, all nodes, before bootstrap ([Deploy Cilium][cilium-talos]):

```yaml
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
```

The module validates `config_contract >= v1.14` and renders only multi-document configs; the pre-1.14 form
(`cluster.network.cni.name: none`, `cluster.proxy.disabled: true`) is not supported. A contract bump is a
deliberate migration.

Talos values of the `cilium` catalog component, set per cluster in `gitops/clusters/<name>/cluster.yaml`
("Without kube-proxy" and "+ Gateway API" tabs):

```yaml
ipam:
  mode: kubernetes          # required on Talos
kubeProxyReplacement: true
k8sServiceHost: localhost   # KubePrism
k8sServicePort: 7445
securityContext:
  capabilities:             # no SYS_MODULE: Talos forbids workloads from loading modules
    ciliumAgent: [CHOWN, KILL, NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN, SYS_RESOURCE, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    cleanCiliumState: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]
cgroup:
  autoMount:
    enabled: false          # Talos already mounts cgroup2 and bpffs
  hostRoot: /sys/fs/cgroup
gatewayAPI:
  enabled: true
  enableAlpn: true          # "required to negotiate HTTP/2": GRPCRoute over TLS
  enableAppProtocol: true
```

| Rule | Why |
| --- | --- |
| `bootstrap-cilium` applies `rendered/cilium/`, never an inline manifest (ADR-0015). | [Inline manifests](0025-talos-raspberry-pi-options.md#talos-inline-manifests) would fight Argo CD; the bootstrap reuses the reviewed rendered files, so kind and Talos share one path. |
| Talos values are per-cluster overrides of the `cilium` component in `cluster.yaml` (ADR-0006), not the full upstream `values.yaml` templated by homelab (186 KB). | Talos deltas stay reviewable; no values outside the catalog. |
| `gateway-api-crds` ships every CRD [Cilium requires][cilium-gw] from Gateway API v1.6.3, pinned and bumped with Cilium: GatewayClass, Gateway, HTTPRoute, GRPCRoute, BackendTLSPolicy, ReferenceGrant, **TLSRoute**; TCPRoute, UDPRoute, ListenerSet optional. | Cilium does not install them and they "must be installed" first (ADR-0012, ADR-0015). `l7Proxy` stays at its default `true`. |
| `forwardKubeDNSToHost: false` (in `ResolverConfig` `hostDNS`) when Cilium `bpf.masquerade: true`. | Known issue: the default `true` with masquerade can break CoreDNS. |
| Rendered namespace checks allow `pod-security.kubernetes.io/enforce=privileged` on the Cilium connectivity-test namespace only. | The test needs it on Talos. |
| CoreDNS: either Talos owns it (updated by `upgrade-k8s`) and it stays out of the catalog, or `KubeCoreDNSConfig` disables it and a component owns it. Never both. | Same fight as inline manifests ([open question](../rfc/0025-talos-raspberry-pi.md#open-questions)). |
| Without a LoadBalancer at home: `gatewayAPI.hostNetwork.enabled: true`, Cilium LB IPAM with L2 announcements, or `cloudflared` only. | [Open question](../rfc/0025-talos-raspberry-pi.md#open-questions). |

## Sources

- [Cilium (stable): Gateway API support][cilium-gw]
- [Cilium (stable): System Requirements][cilium-req]
- [Sidero Labs, Kubernetes guides: Deploy Cilium CNI, re-checked 2026-11-19][cilium-talos]

[cilium-gw]: https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/
[cilium-req]: https://docs.cilium.io/en/stable/operations/system_requirements/
[cilium-talos]: https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md
