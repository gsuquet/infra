#!/usr/bin/env bash
# Render the three components of experiment gateway-multi into plain YAML,
# the way gitops/clusters/<name>/rendered/<component>/ will be produced.
#
# Usage: render.sh <out-dir> [gateway-api-version] [gateway-api-channel]
# The Gateway API version/channel default to components/gateway-api-crds/component.yaml.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: render.sh <out-dir> [gateway-api-version] [channel]}"
gw_version="${2:-$(yq '.source.version' "$here/components/gateway-api-crds/component.yaml")}"
gw_channel="${3:-$(yq '.source.channel' "$here/components/gateway-api-crds/component.yaml")}"

mkdir -p "$out"/{gateway-api-crds,cilium,agentgateway}

# gateway-api-crds: the checksum file is the file list, so a tag cannot add or
# change a file without the render failing.
sums="$here/components/gateway-api-crds/checksums/${gw_version}-${gw_channel}.sha256"
[[ -f "$sums" ]] || { echo "no checksums for ${gw_version}/${gw_channel}: $sums" >&2; exit 1; }
base="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${gw_version}/config/crd/${gw_channel}"
while read -r _ file; do
  curl -fsSL --retry 3 -o "$out/gateway-api-crds/$file" "$base/$file"
done <"$sums"
(cd "$out/gateway-api-crds" && shasum -a 256 -c "$sums" >/dev/null) || {
  echo "checksum mismatch for gateway-api ${gw_version}/${gw_channel}" >&2
  exit 1
}

# cilium
c_ver="$(yq '.source.version' "$here/components/cilium/component.yaml")"
helm template cilium cilium --repo https://helm.cilium.io --version "$c_ver" \
  --namespace kube-system -f "$here/components/cilium/values.yaml" \
  >"$out/cilium/manifests.yaml"

# agentgateway: CRDs chart first (sync wave -1 in Argo CD), then the controller.
a_ver="$(yq '.source[0].version' "$here/components/agentgateway/component.yaml")"
helm template agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --version "$a_ver" --namespace agentgateway-system >"$out/agentgateway/crds.yaml"
helm template agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version "$a_ver" --namespace agentgateway-system \
  -f "$here/components/agentgateway/values.yaml" >"$out/agentgateway/manifests.yaml"

# Ownership guard (future Conftest rule): only gateway-api-crds may ship
# gateway.networking.k8s.io / gateway.networking.x-k8s.io CRDs.
for comp in cilium agentgateway; do
  owned="$(yq -N 'select(.kind == "CustomResourceDefinition" and (.spec.group | test("^gateway\.networking\.(x-)?k8s\.io$"))) | .metadata.name' "$out/$comp"/*.yaml)"
  if [[ -n "$owned" ]]; then
    echo "component $comp bundles Gateway API CRDs:" >&2
    echo "$owned" >&2
    exit 1
  fi
done

echo "rendered gateway-api ${gw_version}/${gw_channel}, cilium ${c_ver}, agentgateway ${a_ver} into $out"
