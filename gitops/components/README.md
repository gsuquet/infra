# Components

The catalog: one folder per component, `gitops/components/<name>/`, holding its Helm source (chart reference and
pinned version) and default values ([ADR-0006](../../docs/adr/0006-component-catalog-and-cluster-file.md)).

A component is enabled per cluster in `gitops/clusters/<name>/cluster.yaml`. Nothing here is applied directly:
`mise run manifests:render` writes the output to `gitops/clusters/<name>/rendered/<component>/`.

Baseline on every cluster: `gateway-api-crds`, `cilium` (not GKE), `argocd`, `cert-manager`, `external-secrets`
([ADR-0014](../../docs/adr/0014-baseline-components.md)). Gateway API implementations are installed without
their bundled CRDs and own one `GatewayClass` each
([ADR-0012](../../docs/adr/0012-gateway-api-crd-ownership.md)).
