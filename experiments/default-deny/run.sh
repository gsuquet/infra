#!/usr/bin/env bash
# Experiment 2 (default-deny): Cilium clusterwide default-deny on kind, minimal
# allow profiles for Argo CD, cert-manager, external-secrets and a tenant.
#
# Creates the kind cluster "exp-default-deny", runs every check, writes the
# evidence to out/, and ALWAYS deletes the cluster on exit (success, failure or
# Ctrl-C). Exit code: number of checks whose result differed from expectation.
#
# Usage (from anywhere): mise trust experiments/default-deny/mise.toml && \
#   mise -C experiments/default-deny install && experiments/default-deny/run.sh
# KIND_CONFIG=kind-multinode.yaml runs the two-node variant.
# MIN_FREE_GIB_PER_NODE (default 4) gates the start on free Docker memory.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER=exp-default-deny
CTX="kind-${CLUSTER}"
OUT="${HERE}/out"

# Pinned chart versions (see docs/research/experiments/default-deny.md).
CILIUM_CHART_VERSION=1.20.5
ARGOCD_CHART_VERSION=10.18.1
CERT_MANAGER_CHART_VERSION=v1.21.3
ESO_CHART_VERSION=2.15.0

# Re-exec under the experiment's pinned toolchain.
if [[ -z "${EXP_DEFAULT_DENY_MISE:-}" ]]; then
  cd "${HERE}"
  EXP_DEFAULT_DENY_MISE=1 exec mise exec -- bash "${HERE}/run.sh" "$@"
fi
cd "${HERE}"

# Keep Helm's caches and repo config out of the user's home.
WORK="$(mktemp -d)"
export HELM_CACHE_HOME="${WORK}/helm/cache" HELM_CONFIG_HOME="${WORK}/helm/config" HELM_DATA_HOME="${WORK}/helm/data"

k() { kubectl --context "${CTX}" "$@"; }
log() { printf '\n== %s\n' "$*" | tee -a "${OUT}/run.log"; }

cleanup() {
  local rc=$?
  log "cleanup: deleting kind cluster ${CLUSTER}"
  kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
  exit "${rc}"
}

# --- preflight -------------------------------------------------------------
rm -rf "${OUT}" && mkdir -p "${OUT}"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "kind cluster ${CLUSTER} already exists; delete it first" >&2
  exit 1
fi
trap cleanup EXIT INT TERM
{
  echo "existing kind clusters: $(kind get clusters 2>/dev/null | tr '\n' ' ')"
  docker info --format 'docker: {{.NCPU}} CPUs, {{.MemTotal}} bytes memory'
  kind version
  kubectl version --client | head -1
  helm version --short
  jq --version
  yq --version
} | tee "${OUT}/preflight.txt"

# Memory gate: the host (Docker VM) is shared with other agents' kind clusters.
# Refuse to start unless MemTotal minus what existing kind nodes already use
# leaves MIN_FREE_GIB_PER_NODE for each node of this cluster.
MIN_FREE_GIB_PER_NODE="${MIN_FREE_GIB_PER_NODE:-4}"
to_bytes() { # "1.5GiB" -> bytes (docker stats units)
  awk '{ v = $1 + 0; u = $1; sub(/^[0-9.]+/, "", u)
         m = (u == "KiB") ? 1024 : (u == "MiB") ? 1048576 : (u == "GiB") ? 1073741824 : (u == "TiB") ? 1099511627776 : 1
         printf "%d\n", v * m }' <<<"$1"
}
mem_total=$(docker info --format '{{.MemTotal}}')
mem_used=0
kind_nodes=$(docker ps --filter label=io.x-k8s.kind.cluster --format '{{.Names}}')
for c in ${kind_nodes}; do
  usage=$(docker stats --no-stream --format '{{.MemUsage}}' "${c}" | awk '{print $1}')
  mem_used=$((mem_used + $(to_bytes "${usage}")))
done
new_nodes=$(grep -cE '^[[:space:]]*-[[:space:]]*role:' "${KIND_CONFIG:-kind.yaml}")
need=$((new_nodes * MIN_FREE_GIB_PER_NODE * 1073741824))
free=$((mem_total - mem_used))
{
  echo "existing kind nodes: ${kind_nodes:-none}" | tr '\n' ' '
  echo
  echo "memory: total=$((mem_total / 1048576))MiB used-by-kind=$((mem_used / 1048576))MiB free=$((free / 1048576))MiB need=$((need / 1048576))MiB (${new_nodes} node(s) x ${MIN_FREE_GIB_PER_NODE}GiB)"
} | tee -a "${OUT}/preflight.txt"
if ((free < need)); then
  echo "not enough Docker memory for ${new_nodes} node(s); delete other kind clusters or lower MIN_FREE_GIB_PER_NODE" >&2
  exit 1
fi

# --- results bookkeeping ---------------------------------------------------
MISMATCHES=0
RESULTS="${OUT}/results.tsv"
printf 'id\texpected\tactual\tverdict\tdescription\n' >"${RESULTS}"

# check <id> <pass|fail> <description> -- <command...>
check() {
  local id=$1 expected=$2 desc=$3
  shift 4
  local actual=fail
  if "$@" >>"${OUT}/checks.log" 2>&1; then actual=pass; fi
  local verdict=OK
  if [[ "${actual}" != "${expected}" ]]; then verdict=MISMATCH; MISMATCHES=$((MISMATCHES + 1)); fi
  printf '%s\t%s\t%s\t%s\t%s\n' "${id}" "${expected}" "${actual}" "${verdict}" "${desc}" | tee -a "${RESULTS}"
}
# Probe helpers run inside the agnhost pods.
http() { # http <ns> <pod> <url>
  echo "--- http $1/$2 -> $3" >>"${OUT}/checks.log"
  k -n "$1" exec "$2" -- curl -sk -o /dev/null -m 5 -w '%{http_code}\n' "$3"
}
dns() { # dns <ns> <pod> <name>
  echo "--- dns $1/$2 -> $3" >>"${OUT}/checks.log"
  k -n "$1" exec "$2" -- sh -c "dig +short +time=3 +tries=1 '$3' | grep -q ."
}
wait_cond() { # wait_cond <timeout-seconds> <command...>
  local t=$1
  shift
  local end=$((SECONDS + t))
  until "$@"; do
    ((SECONDS < end)) || return 1
    sleep 5
  done
}
app_compared() { # Application compared without error (repo reachable)
  local s
  s=$(k -n argocd get application "$1" -o json 2>/dev/null) || return 1
  jq -e '(.status.sync.status == "Synced" or .status.sync.status == "OutOfSync")
         and ([.status.conditions[]? | select(.type == "ComparisonError")] | length == 0)' <<<"${s}" >/dev/null
}
drops() { # dump Hubble drops from every Cilium agent
  local f="${OUT}/drops-$1.txt"
  : >"${f}"
  for p in $(k -n kube-system get pods -l k8s-app=cilium -o name); do
    echo "### ${p}" >>"${f}"
    k -n kube-system exec "${p}" -c cilium-agent -- \
      hubble observe --verdict DROPPED --last 2000 -o compact >>"${f}" 2>&1 || true
  done
}
render() { # render <release> <namespace> <values> <chart args...>
  local rel=$1 ns=$2 values=$3
  shift 3
  helm template "${rel}" "$@" --namespace "${ns}" --values "${values}" --include-crds
}

# --- cluster + Cilium ------------------------------------------------------
log "create kind cluster"
kind create cluster --config "${KIND_CONFIG:-kind.yaml}" --wait 0s 2>&1 | tee -a "${OUT}/run.log"

log "install Cilium ${CILIUM_CHART_VERSION} (kube-proxy replacement)"
render cilium kube-system values/cilium.yaml oci://quay.io/cilium/charts/cilium --version "${CILIUM_CHART_VERSION}" \
  | k apply --server-side -f - >/dev/null
k -n kube-system rollout status ds/cilium --timeout=300s
k -n kube-system rollout status deploy/cilium-operator --timeout=300s
k wait --for=condition=Ready nodes --all --timeout=300s
k -n kube-system rollout status deploy/coredns --timeout=180s
k -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief | tee -a "${OUT}/run.log"
k -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|Proxy Status|Hubble' | tee "${OUT}/cilium-status.txt"
k -n kube-system get cm cilium-config -o json | jq -r '.data | to_entries[] | select(.key | test("policy|localhost|dns|kube-proxy")) | "\(.key)=\(.value)"' >"${OUT}/cilium-config.txt"

# --- phase A: baseline only (cluster layer first, like the real bootstrap) --
log "phase A: namespaces + baseline default-deny, no component policies"
k apply -f manifests/namespaces.yaml
k apply -f policies/baseline/default-deny.yaml
# Kubelet probe allows (needed under allow-localhost=policy) so readiness is not
# the variable in phase A: pods are Ready, only the component CNPs are missing.
k apply -f policies/kubelet-probes/
k apply -f manifests/probes.yaml
for ns in tenant-a tenant-b gateway monitoring; do k -n "${ns}" wait --for=condition=Ready pod --all --timeout=180s; done

log "phase A: install components as rendered manifests"
render argocd argocd values/argocd.yaml argo-cd --repo https://argoproj.github.io/argo-helm --version "${ARGOCD_CHART_VERSION}" \
  | k apply --server-side -f - >/dev/null
render cert-manager cert-manager values/cert-manager.yaml oci://quay.io/jetstack/charts/cert-manager --version "${CERT_MANAGER_CHART_VERSION}" \
  | k apply --server-side -f - >/dev/null
render external-secrets external-secrets values/external-secrets.yaml external-secrets --repo https://charts.external-secrets.io --version "${ESO_CHART_VERSION}" \
  | k apply --server-side -f - >/dev/null
k wait --for=condition=Established crd --all --timeout=120s >/dev/null

log "phase A: give components 150s to settle under baseline only"
sleep 150
for ns in argocd cert-manager external-secrets; do k -n "${ns}" get pods -o wide; done | tee "${OUT}/phaseA-pods.txt"
k -n cert-manager logs job/cert-manager-startupapicheck --tail=5 >"${OUT}/phaseA-startupapicheck.txt" 2>&1 || true
k -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
k -n external-secrets rollout status deploy/external-secrets-webhook --timeout=180s
drops phaseA

check A1 pass "tenant-a DNS lookup through DNS proxy" -- dns tenant-a client kubernetes.default.svc.cluster.local
check A2 pass "tenant-a -> kube-apiserver (baseline)" -- http tenant-a client https://kubernetes.default.svc/healthz
check A3 fail "tenant-a client -> tenant-a server (same namespace, denied)" -- http tenant-a client http://server.tenant-a.svc/hostname
check A4 fail "tenant-a -> world (github.com:443)" -- http tenant-a client https://github.com
only() { yq "select(.kind == \"$1\")" manifests/component-checks.yaml; }
# allow-localhost=policy (values/cilium.yaml): host -> local pod traffic is
# policed, so even on one node, where kube-apiserver carries the host identity,
# the webhook call must be denied until the component CNP allows
# kube-apiserver -> pod:10250. Webhook pods are Ready (kubelet-probes CNPs).
check A5 fail "cert-manager webhook without allow (allow-localhost=policy)" -- \
  k apply --request-timeout=40s -f <(only Issuer)
check A6 fail "ESO webhook without allow (allow-localhost=policy)" -- \
  k apply --request-timeout=40s -f <(only SecretStore)
k apply -f <(only Application)
check A7 fail "argocd: compare github.com repo without component policies" -- \
  wait_cond 90 app_compared github-probe
k -n argocd get application github-probe -o jsonpath='{.status.conditions}{"\n"}' >"${OUT}/phaseA-github-probe.txt" 2>&1 || true

# --- phase B: component profiles --------------------------------------------
log "phase B: apply component policies"
k apply -f policies/components/
# Late policy: do components recover on their own once their CNPs land, without
# a restart? Argo CD retries the comparison at the next reconciliation (3 min
# plus jitter).
check B0 pass "argocd recovers without restart once its CNPs land (late policy)" -- \
  wait_cond 300 app_compared github-probe
# Restart so every component starts clean under the final policy set.
for ns in argocd cert-manager external-secrets; do
  k -n "${ns}" rollout restart deploy >/dev/null 2>&1 || true
done
k -n argocd rollout restart statefulset >/dev/null 2>&1 || true
# The startupapicheck Job has exhausted its retries in phase A: run it again.
k -n cert-manager delete job cert-manager-startupapicheck --wait=true >/dev/null 2>&1 || true
render cert-manager cert-manager values/cert-manager.yaml oci://quay.io/jetstack/charts/cert-manager --version "${CERT_MANAGER_CHART_VERSION}" \
  | yq 'select(.kind == "Job")' | k apply --server-side -f - >/dev/null

for ns in argocd cert-manager external-secrets; do
  for d in $(k -n "${ns}" get deploy -o name); do k -n "${ns}" rollout status "${d}" --timeout=300s; done
done
k -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
check B1 pass "cert-manager startupapicheck Job completes (webhook via kube-apiserver entity)" -- \
  k -n cert-manager wait --for=condition=Complete job/cert-manager-startupapicheck --timeout=240s

k apply -f manifests/component-checks.yaml
check B2 pass "cert-manager: self-signed Certificate Ready" -- \
  k -n tenant-a wait --for=condition=Ready certificate/probe --timeout=120s
check B3 pass "cert-manager: ACME ClusterIssuer registered with LE staging (toFQDNs)" -- \
  k wait --for=condition=Ready clusterissuer/letsencrypt-staging --timeout=120s
{
  k get clusterissuer letsencrypt-staging -o jsonpath='{.status}{"\n"}'
  k -n cert-manager logs deploy/cert-manager --tail=200 | grep -iE 'acme|letsencrypt|error' | tail -20
} >"${OUT}/phaseB-acme.txt" 2>&1 || true
check B4 pass "ESO: ExternalSecret from SecretStore 'secrets' synced" -- \
  k -n tenant-a wait --for=condition=Ready externalsecret/db --timeout=120s
check B5 pass "argocd: repo-server compares github.com repo (toFQDNs github.com)" -- \
  wait_cond 180 app_compared github-probe
k -n argocd get application github-probe -o jsonpath='{.status.sync.status}{"\n"}{.status.conditions}{"\n"}' >"${OUT}/phaseB-github-probe.txt" 2>&1 || true

check B6 pass "monitoring -> cert-manager metrics :9402" -- http monitoring scraper http://cert-manager.cert-manager.svc:9402/metrics
check B7 pass "monitoring -> external-secrets metrics :8080" -- http monitoring scraper http://external-secrets-metrics.external-secrets.svc:8080/metrics
check B8 pass "monitoring -> argocd repo-server metrics :8084" -- http monitoring scraper http://argocd-repo-server-metrics.argocd.svc:8084/metrics
check B9 pass "monitoring -> argocd application-controller metrics :8082" -- http monitoring scraper http://argocd-application-controller-metrics.argocd.svc:8082/metrics
check B15 pass "monitoring -> argocd-server metrics :8083" -- http monitoring scraper http://argocd-server-metrics.argocd.svc:8083/metrics
check B16 pass "monitoring -> argocd applicationset metrics :8080" -- http monitoring scraper http://argocd-applicationset-controller-metrics.argocd.svc:8080/metrics
check B17 fail "monitoring -> argocd-server API :8080 (metrics policy must not open it)" -- http monitoring scraper http://argocd-server.argocd.svc/healthz
check B10 fail "tenant-b -> cert-manager metrics (not a monitoring namespace)" -- http tenant-b client http://cert-manager.cert-manager.svc:9402/metrics
check B11 pass "gateway -> argocd-server :80" -- http gateway proxy http://argocd-server.argocd.svc/healthz
check B12 fail "tenant-b -> argocd-server :80" -- http tenant-b client http://argocd-server.argocd.svc/healthz
check B13 fail "argocd repo-server egress to a non-allowed FQDN (gitlab.com)" -- \
  k -n argocd exec deploy/argocd-repo-server -c repo-server -- git ls-remote https://gitlab.com/gitlab-org/gitlab-foss.git HEAD
check B14 pass "argocd repo-server egress to github.com" -- \
  k -n argocd exec deploy/argocd-repo-server -c repo-server -- git ls-remote https://github.com/argoproj/argocd-example-apps.git HEAD
drops phaseB

# --- phase C: tenant profile -------------------------------------------------
log "phase C: tenant isolation"
check C1 fail "gateway -> tenant-a server before tenant policy" -- http gateway proxy http://server.tenant-a.svc/hostname
k apply -f policies/tenant/tenant-a.yaml
sleep 5
check C2 pass "tenant-a client -> tenant-a server (intra-namespace)" -- http tenant-a client http://server.tenant-a.svc/hostname
check C3 pass "gateway -> tenant-a server" -- http gateway proxy http://server.tenant-a.svc/hostname
check C4 fail "tenant-b -> tenant-a server" -- http tenant-b client http://server.tenant-a.svc/hostname
check C5 fail "tenant-a -> world still denied" -- http tenant-a client https://github.com
check C6 fail "tenant-a -> argocd-server (platform namespace)" -- http tenant-a client http://argocd-server.argocd.svc/healthz

# --- phase D: bypass attempts -------------------------------------------------
log "phase D: tenant bypass with a namespaced CNP (allow-union)"
k apply -f policies/tests/tenant-bypass.yaml
sleep 5
check D1 pass "tenant-a CNP 'toEntities: world' opens world egress (union bypass works)" -- http tenant-a client https://github.com
k apply -f policies/tests/cluster-deny.yaml
sleep 5
check D2 fail "tenant-scoped clusterwide egressDeny 1.0.0.1 beats the tenant allow" -- http tenant-a client https://1.0.0.1
check D3 pass "control: 1.1.1.1 still reachable through the tenant allow" -- http tenant-a client https://1.1.1.1
k delete -f policies/tests/tenant-bypass.yaml -f policies/tests/cluster-deny.yaml
sleep 5
check D4 fail "after removing the bypass, world egress is denied again" -- http tenant-a client https://github.com

log "phase D: AppProject blocks a tenant Application that carries a CNP"
helm package fixtures/tenant-bypass -d "${WORK}/repo" >/dev/null
helm repo index "${WORK}/repo" --url http://charts.exp-fixtures.svc.cluster.local
k -n exp-fixtures create configmap chart-repo --from-file="${WORK}/repo" >/dev/null
k apply -f manifests/fixtures-repo.yaml
k -n exp-fixtures rollout status deploy/charts --timeout=120s
# Wait until the repo-server can fetch the index: a first failed fetch is only
# retried at the next reconciliation (3 min), which made this check flaky.
repo_ready() { k -n argocd exec deploy/argocd-repo-server -c repo-server -- helm show chart --repo http://charts.exp-fixtures.svc.cluster.local tenant-bypass >/dev/null 2>&1; }
wait_cond 120 repo_ready
k apply -f manifests/appproject.yaml
blocked() {
  local s
  s=$(k -n argocd get application tenant-a-bypass -o json) || return 1
  jq -r '[.status.conditions[]?.message, .status.operationState.message] | join(" | ")' <<<"${s}" >"${OUT}/phaseD-appproject.txt"
  grep -qi 'not permitted' "${OUT}/phaseD-appproject.txt"
}
check D5 pass "Argo CD refuses the CNP: 'not permitted in project'" -- wait_cond 180 blocked
check D6 fail "tenant-bypass CNP was not created in tenant-a" -- k -n tenant-a get cnp tenant-bypass
{
  k -n exp-fixtures get pods,endpointslices -o wide
  k -n argocd get application tenant-a-bypass -o jsonpath='{.status}{"\n"}'
  for p in $(k -n kube-system get pods -l k8s-app=cilium -o name); do
    k -n kube-system exec "${p}" -c cilium-agent -- hubble observe --pod argocd/argocd-repo-server --last 40 -o compact
  done
} >"${OUT}/phaseD-debug.txt" 2>&1 || true

log "phase D: host-network pods (not Cilium endpoints) are rejected by Pod Security Admission"
check D7 fail "hostNetwork pod in tenant-a rejected (PSA baseline)" -- \
  k -n tenant-a apply --dry-run=server -f manifests/hostnetwork-pod.yaml
check D8 pass "control: same pod accepted in exp-fixtures (no PSA label)" -- \
  k -n exp-fixtures apply --dry-run=server -f manifests/hostnetwork-pod.yaml

log "phase D: pod label spoofing a namespace label"
k apply -f policies/tests/label-spoof.yaml
k -n tenant-b wait --for=condition=Ready pod/spoof --timeout=120s
k -n tenant-b get pod spoof -o jsonpath='{.metadata.labels}{"\n"}' >"${OUT}/phaseD-spoof.txt"
k -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list -o json \
  | jq -r '.[] | select(.status.identity.labels[]? | test("k8s:app=spoof")) | .status.identity.labels[]' >>"${OUT}/phaseD-spoof.txt" 2>&1 || true
check D9 fail "spoofed pod (role=gateway pod label) -> argocd-server" -- http tenant-b spoof http://argocd-server.argocd.svc/healthz
check D10 fail "spoofed pod (role=gateway pod label) -> tenant-a server" -- http tenant-b spoof http://server.tenant-a.svc/hostname
spoof_dropped_at_ingress() { # the egress allow worked, the destination refused
  local f="${OUT}/phaseD-spoof-verdicts.txt"
  : >"${f}"
  for p in $(k -n kube-system get pods -l k8s-app=cilium -o name); do
    k -n kube-system exec "${p}" -c cilium-agent -- \
      hubble observe --type policy-verdict --from-pod tenant-b/spoof --last 200 -o compact >>"${f}" 2>&1 || true
  done
  grep -q 'INGRESS DENIED' "${f}" && ! grep -q 'EGRESS DENIED' "${f}"
}
check D11 pass "spoof flows denied at destination ingress, not source egress" -- spoof_dropped_at_ingress
k delete -f policies/tests/label-spoof.yaml --wait=false
drops phaseD

# --- identities (pitfalls evidence) ------------------------------------------
log "identities seen by Cilium"
cp_ip=$(k get node "${CLUSTER}-control-plane" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
# Ask the agent on the node that runs the webhooks (the worker when multi-node).
webhook_node=$(k -n cert-manager get pod -l app.kubernetes.io/name=webhook -o jsonpath='{.items[0].spec.nodeName}')
worker_pod=$(k -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="${webhook_node}" -o name)
{
  echo "control-plane InternalIP: ${cp_ip}"
  k -n kube-system exec "${worker_pod}" -c cilium-agent -- cilium-dbg ip get "${cp_ip}/32" || true
  k -n kube-system exec "${worker_pod}" -c cilium-agent -- cilium-dbg identity get 7 || true
  k -n kube-system exec "${worker_pod}" -c cilium-agent -- cilium-dbg ip list -n | grep -E "IP|${cp_ip}" || true
} >"${OUT}/identities.txt" 2>&1
cat "${OUT}/identities.txt"

log "results"
column -t -s $'\t' "${RESULTS}" | tee "${OUT}/results.txt"
echo "mismatches: ${MISMATCHES}" | tee -a "${OUT}/results.txt"
exit "${MISMATCHES}"
