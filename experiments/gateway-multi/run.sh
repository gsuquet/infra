#!/usr/bin/env bash
# Experiment gateway-multi: one Gateway API CRD owner, two implementations
# (Cilium + agentgateway) on a throwaway kind cluster, then CRD bumps.
#
# Creates kind cluster exp-gateway-multi, tests, and ALWAYS deletes it
# (set KEEP=1 to keep it for debugging). Evidence lands in $OUT.
#
# Env: GWAPI_FROM (default v1.6.3, the recommended pin, installed fresh before
# Cilium starts), GWAPI_BUMPS (default "v1.7.0"), OUT. The first runs in the
# write-up used GWAPI_FROM=v1.5.1 GWAPI_BUMPS="v1.6.3 v1.7.0".
# The last bump is rolled back to the version before it at the end.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
eval "$(mise env -s bash)"

cluster=exp-gateway-multi
ctx="kind-$cluster"
from="${GWAPI_FROM:-v1.6.3}"
read -r -a bumps <<<"${GWAPI_BUMPS:-v1.7.0}"
((${#bumps[@]} > 0)) || { echo "GWAPI_BUMPS needs at least one version" >&2; exit 1; }
# Template form works with both BSD and GNU mktemp.
out="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/gateway-multi.XXXXXX")}"
mkdir -p "$out"

k() { kubectl --context "$ctx" "$@"; }
step() { printf '\n=== %s\n' "$*"; }

cleanup() {
  local rc=$?
  if [[ "${KEEP:-0}" == "1" ]]; then
    echo "KEEP=1: cluster $cluster left running; delete with: kind delete cluster --name $cluster"
  else
    step "delete cluster $cluster"
    kind delete cluster --name "$cluster" || true
  fi
  echo "evidence in $out (exit $rc)"
}

# --- preflight -------------------------------------------------------------
step "preflight"
if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
  echo "cluster $cluster already exists; refusing to reuse it" >&2
  exit 1
fi
echo "other kind clusters: $(kind get clusters 2>/dev/null | tr '\n' ' ')"
docker info --format 'docker: {{.NCPU}} CPUs, {{.MemTotal}} bytes memory'
# Refuse to start when existing kind nodes leave less than MIN_FREE_MIB
# (default 3 GiB; the node peaks are recorded in $out/node-memory.txt).
total_mib=$(($(docker info --format '{{.MemTotal}}') / 1048576))
read -r -a kind_nodes <<<"$(docker ps -q --filter label=io.x-k8s.kind.cluster | tr '\n' ' ')"
used_mib=0
((${#kind_nodes[@]} > 0)) && used_mib="$(docker stats --no-stream --format '{{.MemUsage}}' "${kind_nodes[@]}" \
  | awk '{v=$1; if (v ~ /GiB/) {sub(/GiB/,"",v); s+=v*1024} else if (v ~ /MiB/) {sub(/MiB/,"",v); s+=v}} END {printf "%d", s}')"
echo "kind nodes already use ${used_mib:-0} MiB of ${total_mib} MiB"
if ((total_mib - ${used_mib:-0} < ${MIN_FREE_MIB:-3072})); then
  echo "less than ${MIN_FREE_MIB:-3072} MiB left for a new node; aborting" >&2
  exit 1
fi
trap cleanup EXIT

step "render (gateway-api $from and ${bumps[*]})"
./render.sh "$out/rendered-$from" "$from" standard
for v in "${bumps[@]}"; do
  ./render.sh "$out/rendered-$v" "$v" standard
done

# --- cluster + baseline ------------------------------------------------------
step "create kind cluster"
kind create cluster --config kind.yaml --wait 0s
k get nodes -o wide

apply_crds() {
  local dir="$1"
  k apply --server-side --force-conflicts -f "$dir/gateway-api-crds/"
  local crds
  read -r -a crds <<<"$(yq -N 'select(.kind == "CustomResourceDefinition") | "crd/" + .metadata.name' \
    "$dir"/gateway-api-crds/*.yaml | tr '\n' ' ')"
  k wait --for=condition=Established --timeout=60s "${crds[@]}"
}

step "gateway-api-crds $from (standalone component, before any implementation)"
apply_crds "$out/rendered-$from"

step "cilium (no Gateway API CRDs in its render)"
k apply --server-side -f "$out/rendered-$from/cilium/manifests.yaml"
k -n kube-system rollout status ds/cilium --timeout=300s
k -n kube-system rollout status deploy/cilium-operator --timeout=300s
k -n kube-system rollout status ds/cilium-envoy --timeout=300s
k wait --for=condition=Ready node --all --timeout=120s

step "LB-IPAM pool (in-cluster only, no L2 announcement)"
until k get crd ciliumloadbalancerippools.cilium.io >/dev/null 2>&1; do sleep 2; done
k apply -f - <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: exp
spec:
  blocks:
    - start: 172.18.255.200
      stop: 172.18.255.220
YAML

step "agentgateway (own CRDs, then controller)"
k create namespace agentgateway-system --dry-run=client -o yaml | k apply -f -
k apply --server-side -f "$out/rendered-$from/agentgateway/crds.yaml"
k apply --server-side -f "$out/rendered-$from/agentgateway/manifests.yaml"
k -n agentgateway-system rollout status deploy/agentgateway --timeout=300s

step "GatewayClasses accepted"
until k get gatewayclass agentgateway >/dev/null 2>&1; do sleep 2; done
k wait --for=condition=Accepted --timeout=120s gatewayclass/cilium gatewayclass/agentgateway
k get gatewayclass -o wide | tee "$out/gatewayclasses-$from.txt"

step "backend, Gateways and HTTPRoutes"
k apply -f manifests/backend.yaml
k -n demo rollout status deploy/echo --timeout=180s
k apply -f manifests/gateways.yaml
k -n demo wait --for=condition=Programmed --timeout=180s gateway/gw-cilium gateway/gw-agentgateway
k -n demo run curl --image=curlimages/curl:8.17.0 --restart=Never --command -- sleep 3600
k -n demo wait --for=condition=Ready --timeout=120s pod/curl

probe() {
  local tag="$1" gw host addr rc=0
  for gw in cilium agentgateway; do
    host="$gw.example.test"
    addr="$(k -n demo get gateway "gw-$gw" -o jsonpath='{.status.addresses[0].value}')"
    k -n demo wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
      --timeout=120s "httproute/echo-$gw"
    if k -n demo exec curl -- curl -fsS --max-time 5 --retry 10 --retry-all-errors --retry-delay 2 \
      -H "Host: $host" "http://$addr/hostname" >"$out/probe-$tag-$gw.txt"; then
      echo "[$tag] $gw via $addr -> $(cat "$out/probe-$tag-$gw.txt")"
    else
      echo "[$tag] $gw via $addr -> FAILED"
      rc=1
    fi
  done
  k get gateway,httproute -A | tee "$out/routes-$tag.txt"
  return "$rc"
}

snapshot() {
  local tag="$1"
  k get crd -o custom-columns='NAME:.metadata.name,BUNDLE:.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version,CHANNEL:.metadata.annotations.gateway\.networking\.k8s\.io/channel' \
    | grep -E 'NAME|gateway.networking' | tee "$out/crds-$tag.txt"
  k get gatewayclass -o yaml >"$out/gatewayclasses-$tag.yaml"
  k -n kube-system logs deploy/cilium-operator --tail=-1 >"$out/cilium-operator-$tag.log"
  k -n agentgateway-system logs deploy/agentgateway --tail=-1 >"$out/agentgateway-$tag.log"
  echo "$tag $(docker stats --no-stream --format '{{.MemUsage}}' "$cluster-control-plane")" >>"$out/node-memory.txt"
}

step "probe on gateway-api $from"
probe "$from"
snapshot "$from"

# --- CRD bumps ---------------------------------------------------------------
for v in "${bumps[@]}"; do
  step "bump gateway-api-crds -> $v (controllers not restarted)"
  apply_crds "$out/rendered-$v"
  sleep 10
  probe "$v-norestart" || echo "probe failed after bump to $v without restart"
  snapshot "$v-norestart"

  step "restart controllers on $v"
  k -n kube-system rollout restart deploy/cilium-operator
  k -n agentgateway-system rollout restart deploy/agentgateway
  k -n kube-system rollout status deploy/cilium-operator --timeout=180s
  k -n agentgateway-system rollout status deploy/agentgateway --timeout=180s
  k wait --for=condition=Accepted --timeout=120s gatewayclass/cilium gatewayclass/agentgateway
  probe "$v-restart"
  snapshot "$v-restart"
done

# --- guard rails from the safe-upgrades ValidatingAdmissionPolicy -----------
versions=("$from" "${bumps[@]}")
last="${versions[${#versions[@]}-1]}"
prev="${versions[${#versions[@]}-2]}"
vap=gateway.networking.k8s.io_vap_safeupgrades.yaml
step "negative: experimental CRD over standard (server dry-run)"
mkdir -p "$out/experimental"
curl -fsSL -o "$out/experimental/gateway.networking.k8s.io_httproutes.yaml" \
  "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/experimental/gateway.networking.k8s.io_httproutes.yaml"
(cd "$out/experimental" && shasum -a 256 -c "$here/components/gateway-api-crds/checksums/v1.6.3-experimental.sha256" >/dev/null)
k apply --server-side --force-conflicts --dry-run=server -f "$out/experimental/gateway.networking.k8s.io_httproutes.yaml" 2>&1 | tee "$out/neg-experimental.txt" || true

step "negative: downgrade to a pre-v1.5 bundle (server dry-run)"
yq '.metadata.annotations."gateway.networking.k8s.io/bundle-version" = "v1.4.1"' \
  "$out/rendered-$last/gateway-api-crds/gateway.networking.k8s.io_gatewayclasses.yaml" \
  | k apply --server-side --force-conflicts --dry-run=server -f - 2>&1 | tee "$out/neg-downgrade-v1.4.txt" || true

step "rollback $last -> $prev, whole directory in one apply (server dry-run)"
# kubectl applies a directory in file-name order, so the VAP file
# (..._vap_safeupgrades.yaml) goes last and every CRD is checked against the
# $last VAP that is still installed.
k apply --server-side --force-conflicts --dry-run=server -f "$out/rendered-$prev/gateway-api-crds/" 2>&1 \
  | tee "$out/rollback-$prev-onepass-dryrun.txt" || true

step "rollback $last -> $prev, VAP + binding first, then CRDs (real apply)"
# This is what an Argo CD sync wave before the CRDs would do. VAP changes reach
# the API server through an informer, so the CRD apply is retried every second (10 tries).
k apply --server-side --force-conflicts -f "$out/rendered-$prev/gateway-api-crds/$vap" \
  | tee "$out/rollback-$prev-vap.txt"
# Time since the VAP apply returned, so the write-up can compare the VAP
# propagation delay with Argo CD's delay between sync waves (bash 3.2 on macOS
# has no EPOCHREALTIME, hence perl).
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
vap_applied="$(now)"
rollback_ok=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  echo "attempt $attempt at +$(awk -v a="$(now)" -v b="$vap_applied" 'BEGIN {printf "%.1f", a - b}')s after the VAP apply"
  if k apply --server-side --force-conflicts -f "$out/rendered-$prev/gateway-api-crds/" \
    >"$out/rollback-$prev-crds-attempt$attempt.txt" 2>&1; then
    rollback_ok=1
    echo "rollback CRD apply succeeded on attempt $attempt"
    break
  fi
  echo "rollback CRD apply attempt $attempt denied:"
  grep -m1 -E 'denied|Error' "$out/rollback-$prev-crds-attempt$attempt.txt" || true
  sleep 1
done
if ((rollback_ok)); then
  snapshot "$prev-rollback"
  k -n kube-system rollout restart deploy/cilium-operator
  k -n agentgateway-system rollout restart deploy/agentgateway
  k -n kube-system rollout status deploy/cilium-operator --timeout=180s
  k -n agentgateway-system rollout status deploy/agentgateway --timeout=180s
  probe "$prev-rollback" || echo "probe failed after rollback to $prev"
else
  echo "ROLLBACK $last -> $prev DENIED even with the VAP applied first" | tee "$out/rollback-$prev-result.txt"
fi

step "done"
