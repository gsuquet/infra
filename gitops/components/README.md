# Components

The catalog: one folder per component, `gitops/components/<name>/`, holding its Helm source (chart reference and
pinned version) and default values.

A component is enabled per cluster in `gitops/clusters/<name>/cluster.yaml`. Nothing here is applied directly:
`mise run manifests:render` writes the output to `gitops/clusters/<name>/rendered/<component>/`.

Baseline on every cluster: `gateway-api-crds` (not GKE), `cilium` (not GKE), `argocd`, `cert-manager`,
`external-secrets`. Gateway API implementations are installed without their bundled CRDs and own one `GatewayClass`
each.
