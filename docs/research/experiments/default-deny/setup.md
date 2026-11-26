# Default-deny experiment setup

What [run 4](results.md) used: commit `6e2ee96`, executed 2026-11-19. The source of truth is
[`experiments/default-deny/`](../../../../experiments/default-deny/).

## Goal

Check the network-policy design before it goes into the component catalog:

- A CCNP puts every namespace that has a policy label into default-deny. `kube-system` is excluded.
- Baseline allows for kube-dns and kube-apiserver.
- Find the smallest allow profile that keeps Argo CD, cert-manager and ESO working: webhooks, Git egress, ACME egress,
  provider egress and metrics.
- Tenant namespace: deny everything, then allow traffic inside the namespace and from the gateway.
- Find out whether a tenant can bypass the default-deny with its own namespaced policy, and what stops it.

## Versions

| Item | Version |
| --- | --- |
| kind | 0.33.0, node `kindest/node:v1.37.0@sha256:a1ed56cf…` (Kubernetes 1.37.0) |
| kubectl / helm / jq / yq | 1.37.2 / 4.3.2 / 1.8.2 / 4.53.6 (`mise.toml` and `mise.lock`) |
| Cilium chart | 1.20.5 (`oci://quay.io/cilium/charts/cilium`), `kubeProxyReplacement: true`, tunnel mode, Hubble without relay, `extraConfig.allow-localhost: policy` |
| Argo CD chart | argo-cd 10.18.1 (Argo CD v3.6.1), no dex, no notifications, chart NetworkPolicies off |
| cert-manager chart | v1.21.3 (`oci://quay.io/jetstack/charts/cert-manager`) |
| external-secrets chart | 2.15.0 |
| Probe images | `agnhost:2.53@sha256:99c6b4bb…`, `nginx:1.29.3-alpine@sha256:b3c656d5…` |

`out/preflight.txt` records exactly the tool versions above. The chart
`appVersion`s were read with `helm show chart` (Cilium, Argo CD and external-secrets match the table) and are not in
`out/preflight.txt`. The run pins the charts but does not record the running Cilium agent version ([re-run review](https://github.com/gsuquet/infra/pull/14#issuecomment-7004346056)).

## Host

Colima with 4 CPUs and 7.7 GiB, with another 2-node kind cluster already running. `run.sh` refuses to start unless
Docker `MemTotal` minus the memory used by existing kind nodes leaves `MIN_FREE_GIB_PER_NODE` (default 4 GiB) per new
node, and prints the existing nodes. Preflight:

```text
memory: total=7920MiB used-by-kind=2014MiB free=5905MiB need=4096MiB (1 node(s) x 4GiB)
```

## Install method

All charts are installed the way the plan installs them: `helm template` piped into `kubectl apply --server-side`. Helm
hooks are therefore plain resources, as in the rendered-manifests pattern.

## Phases

| Phase | What happens |
| --- | --- |
| A | Namespaces, the baseline CCNP, the kubelet-probe allows and probe pods, then the three components. No component policies: the cluster layer lands first |
| B | The component policies land. The run checks that Argo CD compares without a restart, then restarts the components and runs the functional checks |
| C | The tenant profile |
| D | Bypass attempts: a tenant `CiliumNetworkPolicy` (CNP), a clusterwide deny, an Argo CD AppProject, a host-network pod, a pod label that spoofs a namespace label |
