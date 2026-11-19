#!/usr/bin/env bash
# Experiment argocd-adopt: prove the bootstrap boundary on kind.
#
# 1. Render the components with helm template (rendered manifests pattern).
# 2. Mimic Terraform: apply the Gateway API CRDs, Cilium and Argo CD from the
#    rendered files with kubectl server-side apply.
# 3. Create the argocd Application (app of apps) on an in-cluster Git server
#    that holds the same rendered files.
# 4. Check that Argo CD adopts everything, itself included, without restarts,
#    pruning or OutOfSync loops.
# 5. Bump a value of Argo CD, then its chart version, and check that Argo CD
#    upgrades itself; measure the availability of argocd-server meanwhile.
# 6. Check the field managers: removed fields, and a stale re-apply.
#
# The cluster is always deleted at the end, also on failure.
# Usage: ./run.sh   (from this folder, with `mise install` done)
# Inputs (optional): GATEWAY_API_MANIFEST and CILIUM_CHART_TGZ, local copies
# of the pinned artifacts; else run.sh downloads them. Their SHA-256 is checked.
# Switches (optional):
#   REFRESH_SELF=false     do not put the refresh annotation on the argocd
#                          Application itself, only on its children (default
#                          true, as in the runs of the write-up).
#   GENERATE_PATHS=true    set argocd.argoproj.io/manifest-generate-paths: .
#                          on every Application (default false).
#   WATCH_SECONDS=300      length of the OutOfSync loop watch (default 300).
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
readonly CLUSTER=exp-argocd-adopt
readonly NODE_IMAGE=kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
readonly GATEWAY_API_VERSION=v1.6.2
readonly GATEWAY_BUNDLE_SHA256=faede450fa178126aba41337737b97d351ebe87d93c910237ce1e072d1ca40d9
readonly CILIUM_VERSION=1.20.0
readonly CILIUM_CHART_SHA256=c5f013912360d1a334f44ef25f36da59ba3414cdb48f466ee12d0c4fdff27883
readonly ARGOCD_REPO=https://argoproj.github.io/argo-helm
# The digests are the ones of the argo-helm index.yaml.
readonly ARGOCD_FROM=10.11.6
readonly ARGOCD_FROM_SHA256=d8f096d87513b41ff754053a7f9604c943bf29c15436a79226fd51595ea67d05
readonly ARGOCD_TO=10.11.7
readonly ARGOCD_TO_SHA256=9f24a574ead97a1a68af447ab2678073c5e16a98ff9385aee766daf74361f04e
# Terraform will apply with this field manager (see the write-up).
readonly BOOTSTRAP_MANAGER=${BOOTSTRAP_MANAGER:-argocd-controller}
readonly APPS=(argocd cilium gateway-api-crds probe)
readonly REFRESH_SELF=${REFRESH_SELF:-true}
readonly GENERATE_PATHS=${GENERATE_PATHS:-false}
readonly WATCH_SECONDS=${WATCH_SECONDS:-300}

WORK=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/exp-argocd-adopt.XXXXXX")}
readonly WORK
readonly REPO=$WORK/repo
readonly RENDERED=$REPO/gitops/clusters/$CLUSTER/rendered
export KUBECONFIG=$WORK/kubeconfig
mkdir -p "$WORK/inputs" "$WORK/snap"
exec > >(tee -a "$WORK/run.log") 2>&1

log() { printf '\n=== [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

PF_PID=
AVAIL_PID=
WATCH_PID=
CREATED=false
cleanup() {
  local rc=$?
  [[ -n $AVAIL_PID ]] && kill "$AVAIL_PID" 2>/dev/null || true
  [[ -n $PF_PID ]] && kill "$PF_PID" 2>/dev/null || true
  [[ -n $WATCH_PID ]] && kill "$WATCH_PID" 2>/dev/null || true
  if [[ $CREATED == true ]]; then
    log "delete cluster $CLUSTER"
    kind delete cluster --name "$CLUSTER" || true
  fi
  log "exit code $rc, log: $WORK/run.log"
}
trap cleanup EXIT

sha_check() { # file expected
  local got
  got=$(shasum -a 256 "$1" | cut -d' ' -f1)
  [[ $got == "$2" ]] || die "sha256 of $1 is $got, expected $2"
  echo "sha256 ok: $(basename "$1")"
}

# ---------------------------------------------------------------- inputs
fetch_inputs() {
  log "fetch the pinned inputs"
  local gw=$WORK/inputs/gateway-api-standard-install.yaml
  if [[ -n ${GATEWAY_API_MANIFEST:-} ]]; then
    cp "$GATEWAY_API_MANIFEST" "$gw"
  else
    curl -fsSL -o "$gw" "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml"
  fi
  sha_check "$gw" "$GATEWAY_BUNDLE_SHA256"

  local ci=$WORK/inputs/cilium-$CILIUM_VERSION.tgz
  if [[ -n ${CILIUM_CHART_TGZ:-} ]]; then
    cp "$CILIUM_CHART_TGZ" "$ci"
  else
    helm pull cilium --repo https://helm.cilium.io --version "$CILIUM_VERSION" -d "$WORK/inputs"
  fi
  sha_check "$ci" "$CILIUM_CHART_SHA256"

  local v
  for v in "$ARGOCD_FROM" "$ARGOCD_TO"; do
    helm pull argo-cd --repo "$ARGOCD_REPO" --version "$v" -d "$WORK/inputs"
  done
  sha_check "$WORK/inputs/argo-cd-$ARGOCD_FROM.tgz" "$ARGOCD_FROM_SHA256"
  sha_check "$WORK/inputs/argo-cd-$ARGOCD_TO.tgz" "$ARGOCD_TO_SHA256"
}

# ---------------------------------------------------------------- render
render_cilium() { # [extra helm args]
  helm template cilium "$WORK/inputs/cilium-$CILIUM_VERSION.tgz" \
    --namespace kube-system -f "$HERE/values/cilium.yaml" \
    --set k8sServiceHost="$CLUSTER-control-plane" "$@"
}

render_argocd() { # chart-version [extra helm args]
  local version=$1
  shift
  helm template argocd "$WORK/inputs/argo-cd-$version.tgz" \
    --namespace argocd -f "$HERE/values/argocd.yaml" "$@"
}

# Writes rendered/<component>/ as manifests:render will: the chart output,
# the static files of the component, and sync wave -1 on every CRD.
render() { # argocd-chart-version [extra helm args for argocd]
  local version=$1
  shift
  rm -rf "$RENDERED"
  mkdir -p "$RENDERED"/{gateway-api-crds,cilium,argocd,probe}
  cp "$WORK/inputs/gateway-api-standard-install.yaml" "$RENDERED/gateway-api-crds/"
  render_cilium >"$RENDERED/cilium/manifest.yaml"
  render_argocd "$version" "$@" >"$RENDERED/argocd/manifest.yaml"
  cp "$HERE"/components/argocd/*.yaml "$RENDERED/argocd/"
  if [[ $GENERATE_PATHS == true ]]; then
    # Each Application regenerates only when its own folder changes.
    yq -i '(select(.kind == "Application")
      | .metadata.annotations."argocd.argoproj.io/manifest-generate-paths") = "."' \
      "$RENDERED/argocd/platform.yaml"
  fi
  cp "$HERE"/components/probe/*.yaml "$RENDERED/probe/"
  local f
  for f in "$RENDERED"/*/*.yaml; do
    yq -i '(select(.kind == "CustomResourceDefinition")
      | .metadata.annotations."argocd.argoproj.io/sync-wave") = "-1"' "$f"
  done
}

render_check() {
  log "render check: same inputs, same output?"
  local a=$WORK/render-a b=$WORK/render-b
  render_cilium >"$a" && render_cilium >"$b"
  diff -q "$a" "$b" >/dev/null || die "cilium render is not reproducible"
  echo "cilium (our values): reproducible"
  render_argocd "$ARGOCD_FROM" >"$a" && render_argocd "$ARGOCD_FROM" >"$b"
  diff -q "$a" "$b" >/dev/null || die "argo-cd render is not reproducible"
  echo "argo-cd: reproducible"
  render_cilium --set hubble.enabled=true >"$a"
  render_cilium --set hubble.enabled=true >"$b"
  if diff -q "$a" "$b" >/dev/null; then
    echo "cilium with hubble.tls.auto.method=helm (chart default): reproducible"
  else
    echo "cilium with hubble.tls.auto.method=helm (chart default): NOT reproducible:"
    diff "$a" "$b" | grep -E '^[<>] +(ca\.crt|tls\.crt|tls\.key|ca\.key):' \
      | cut -c1-60 | head -4 || true
  fi
}

# ---------------------------------------------------------------- git
git_commit_push() { # message
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=exp -c user.email=exp@example.invalid \
    commit --quiet -m "$1"
  git -C "$REPO" push --quiet origin main
  REV=$(git -C "$REPO" rev-parse HEAD)
  echo "pushed $REV: $1"
}

start_git_server() {
  log "in-cluster git server (experiment scaffolding)"
  kubectl apply -f "$HERE/manifests/git-server.yaml"
  kubectl -n git-server rollout status deploy/git-server --timeout=180s
  # A random local port: other experiments may run in parallel.
  kubectl -n git-server port-forward svc/git-server :9418 >"$WORK/pf.log" 2>&1 &
  PF_PID=$!
  local port=
  for _ in $(seq 1 30); do
    port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+).*/\1/p' "$WORK/pf.log" | head -1)
    [[ -n $port ]] && break
    sleep 1
  done
  [[ -n $port ]] || die "port-forward to git-server did not start"
  git init --quiet -b main "$REPO"
  git -C "$REPO" remote add origin "git://127.0.0.1:$port/infra.git"
}

# ---------------------------------------------------------------- kube helpers
apps_table() {
  {
    printf 'APP\tSYNC\tHEALTH\tREV\tSYNCS\tLAST_OP\n'
    kubectl -n argocd get applications.argoproj.io -o json | jq -r '.items[]
    | [.metadata.name, .status.sync.status, .status.health.status,
       ((.status.sync.revision // "-")[0:8]), (.status.history // [] | length),
       (.status.operationState.phase // "-")] | @tsv'
  } | column -t
}

# Resources of the argocd Application seen OutOfSync, per revision: says what
# made Argo CD sync itself on a commit. A 5 s poll missed the OutOfSync state
# (it lasts less than the poll period), so a watch records every update of the
# Applications from the hand-over on, to $WORK/apps-watch.json.
# Every operation of every Application, from the watch: the status and the
# sync history do not show a partial self-heal sync at the same revision.
show_operations() {
  jq -sr '[.[] | select(.status.operationState.finishedAt != null)
      | {app: .metadata.name, os: .status.operationState}]
    | unique_by([.app, .os.finishedAt]) | sort_by(.os.finishedAt)[]
    | "  \(.os.finishedAt) \(.app) rev \(.os.syncResult.revision[0:8]) \(.os.phase):" +
      " \(.os.syncResult.resources // [] | map(select((.hookType // "") == "")) | length) resources," +
      " \(.os.syncResult.resources // [] | map(select((.hookType // "") != "")) | length) hook resources" +
      (if (.os.operation.sync.resources // []) | length > 0
       then " (partial sync of Application \([.os.operation.sync.resources[] | select(.kind == "Application") | .name] | join(", ")))"
       else "" end)' "$WORK/apps-watch.json" || true
}

start_apps_watch() {
  kubectl -n argocd get applications.argoproj.io -w -o json \
    >"$WORK/apps-watch.json" 2>"$WORK/apps-watch.err" &
  WATCH_PID=$!
}

show_argocd_oos() { # revision
  local w=$WORK/apps-watch.json
  echo "argocd Application resources seen OutOfSync at ${1:0:8} (watch):"
  jq -r --arg rev "$1" 'select(.metadata.name == "argocd"
      and .status.sync.revision == $rev)
    | .status.resources[]? | select(.status == "OutOfSync")
    | "  \(.kind)/\(.namespace // "")/\(.name)"' "$w" | sort -u || true
  echo "(end of list)"
  echo "argocd Application updates at ${1:0:8} (sync status, operation phase):"
  jq -r --arg rev "$1" 'select(.metadata.name == "argocd"
      and .status.sync.revision == $rev)
    | "\(.status.sync.status) \(.status.operationState.phase // "-")"' "$w" \
    | uniq -c | sed 's/^/ /' || true
  kubectl -n argocd get applications.argoproj.io argocd -o json | jq -r '
    "argocd app last sync: rev \((.status.operationState.syncResult.revision // "-")[0:8])," +
    " \([(.status.operationState.syncResult.resources // [])[]
      | select(.hookType == null)] | length) resources applied"'
}

wait_apps() { # revision timeout-seconds
  local rev=$1 deadline=$((SECONDS + $2)) ready
  while ((SECONDS < deadline)); do
    ready=$(kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null | jq --arg rev "$rev" '
      [.items[] | select(.status.sync.status == "Synced"
        and .status.health.status == "Healthy"
        and .status.sync.revision == $rev
        and (.status.operationState.phase // "Succeeded") == "Succeeded")]
      | length' || echo 0)
    if [[ $ready == "${#APPS[@]}" ]]; then
      echo "all ${#APPS[@]} Applications Synced and Healthy at ${rev:0:8}" \
        "after $(($2 - deadline + SECONDS))s"
      return 0
    fi
    sleep 5
  done
  apps_table
  die "Applications not Synced and Healthy at ${rev:0:8} after $2s"
}

refresh_apps() {
  local app
  for app in "${APPS[@]}"; do
    [[ $app == argocd && $REFRESH_SELF != true ]] && continue
    kubectl -n argocd annotate applications.argoproj.io "$app" \
      argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
  done
}

# Long-running pods (Job pods excluded) and workload generations.
snapshot() { # name
  local out=$WORK/snap/$1
  kubectl get pods -A -o json | jq -r '.items[]
    | select(.metadata.namespace == "kube-system" or .metadata.namespace == "argocd")
    | select((.metadata.ownerReferences // [])[0].kind != "Job")
    | [.metadata.namespace, .metadata.name, .metadata.uid[0:8],
       ([.status.containerStatuses[]?.restartCount] | add // 0)] | @tsv' \
    | sort >"$out.pods"
  kubectl get deploy,ds,sts -n kube-system -o json | jq -r '.items[]
    | [.kind, .metadata.namespace, .metadata.name, .metadata.generation] | @tsv' \
    >"$out.workloads"
  kubectl get deploy,sts -n argocd -o json | jq -r '.items[]
    | [.kind, .metadata.namespace, .metadata.name, .metadata.generation] | @tsv' \
    >>"$out.workloads"
  sort -o "$out.workloads" "$out.workloads"
}

compare_snapshots() { # before after
  local b=$WORK/snap/$1 a=$WORK/snap/$2
  if diff "$b.pods" "$a.pods" >"$WORK/snap/$1-$2.pods.diff"; then
    echo "pods: identical (same UIDs, same restart counts, $(wc -l <"$a.pods" | tr -d ' ') pods)"
  else
    echo "pods: CHANGED"
    cat "$WORK/snap/$1-$2.pods.diff"
  fi
  if diff "$b.workloads" "$a.workloads" >"$WORK/snap/$1-$2.wl.diff"; then
    echo "workload generations: identical"
  else
    echo "workload generations: CHANGED"
    cat "$WORK/snap/$1-$2.wl.diff"
  fi
}

# Deployment specs without the pod template, to explain a generation bump.
dump_specs() { # name
  kubectl get deploy -n argocd -o json | jq -S '[.items[]
    | {name: .metadata.name, spec: (.spec | del(.template))}]' \
    >"$WORK/snap/$1.specs"
  kubectl get deploy -n argocd -o json | jq -S '[.items[]
    | {name: .metadata.name, template: .spec.template}]' \
    >"$WORK/snap/$1.templates"
}

managers() { # kind/name namespace
  kubectl get "$1" -n "$2" --show-managed-fields -o json | jq -r '
    .metadata.managedFields[] | "  \(.manager) \(.operation)"'
}

# The API server proxies to the Service: no port-forward to lose on a restart.
start_avail_probe() { # name
  local out=$WORK/avail-$1
  : >"$out"
  (
    while :; do
      if kubectl get --raw \
        /api/v1/namespaces/argocd/services/argocd-server:http/proxy/healthz \
        --request-timeout=2s >/dev/null 2>&1; then
        echo ok >>"$out"
      else
        echo "fail $(date +%H:%M:%S)" >>"$out"
      fi
      sleep 1
    done
  ) &
  AVAIL_PID=$!
}

stop_avail_probe() { # name
  kill "$AVAIL_PID" 2>/dev/null || true
  wait "$AVAIL_PID" 2>/dev/null || true
  AVAIL_PID=
  local out=$WORK/avail-$1
  echo "argocd-server /healthz: $(grep -c '^ok' "$out" || true) ok," \
    "$(grep -c '^fail' "$out" || true) failed probes (1 per second)"
  grep '^fail' "$out" | head -5 || true
}

wait_argocd_rollout() {
  local w
  for w in deploy/argocd-server deploy/argocd-repo-server \
    deploy/argocd-applicationset-controller deploy/argocd-redis \
    sts/argocd-application-controller; do
    kubectl -n argocd rollout status "$w" --timeout=300s >/dev/null
  done
  echo "Argo CD workloads rolled out"
}

# ================================================================ phases
log "versions"
kind version
kubectl version --client | head -1
helm version --short
yq --version
echo "node image: $NODE_IMAGE"
echo "gateway-api $GATEWAY_API_VERSION, cilium $CILIUM_VERSION," \
  "argo-cd chart $ARGOCD_FROM -> $ARGOCD_TO, bootstrap manager: $BOOTSTRAP_MANAGER"
echo "REFRESH_SELF=$REFRESH_SELF GENERATE_PATHS=$GENERATE_PATHS WATCH_SECONDS=$WATCH_SECONDS"

log "capacity check"
kind get clusters 2>/dev/null || true
docker info --format 'docker: {{.NCPU}} CPUs, {{.MemTotal}} bytes memory'
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  die "cluster $CLUSTER already exists; delete it first"
fi

fetch_inputs
render_check

log "phase 1: create the kind cluster (no CNI, no kube-proxy)"
CREATED=true
kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" \
  --config "$HERE/kind.yaml" --kubeconfig "$KUBECONFIG" --wait 0s
kubectl get nodes --no-headers

log "phase 2: render v1 (argo-cd $ARGOCD_FROM)"
render "$ARGOCD_FROM"
cp -R "$RENDERED" "$WORK/rendered-v1"
find "$RENDERED" -name '*.yaml' | sed "s|$RENDERED/||" | sort

# What Terraform will do: server-side apply of the rendered files.
kapply() { kubectl apply --server-side --field-manager="$BOOTSTRAP_MANAGER" "$@"; }

log "phase 3: bootstrap (Terraform mimic) - Gateway API CRDs"
kapply -f "$RENDERED/gateway-api-crds/" | sed 's/^/  /'
kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null

log "phase 3: bootstrap - Cilium"
kapply -f "$RENDERED/cilium/" | wc -l | xargs echo "  objects applied:"
kubectl -n kube-system rollout status ds/cilium --timeout=300s
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl -n kube-system rollout status deploy/coredns --timeout=180s

start_git_server
git_commit_push "render v1: argo-cd $ARGOCD_FROM"
REV_V1=$REV

log "phase 3: bootstrap - Argo CD (namespace and CRDs, then the rest)"
split_dir=$WORK/bootstrap-argocd
mkdir -p "$split_dir"
# A plain cat would glue the last document of one file to the first of the
# next: each file goes in as its own document stream.
for f in "$RENDERED"/argocd/*.yaml; do
  cat "$f"
  printf '\n---\n'
done >"$split_dir/all.yaml"
yq 'select(.kind == "Namespace" or .kind == "CustomResourceDefinition")' \
  "$split_dir/all.yaml" >"$split_dir/1-foundation.yaml"
yq 'select(.kind != "Namespace" and .kind != "CustomResourceDefinition"
  and (.apiVersion | test("^argoproj.io/") | not))' \
  "$split_dir/all.yaml" >"$split_dir/2-components.yaml"
# Only the AppProject and the argocd Application: the argocd Application
# creates the other Applications, in their sync waves.
yq 'select((.apiVersion | test("^argoproj.io/"))
  and (.kind != "Application" or .metadata.name == "argocd"))' \
  "$split_dir/all.yaml" >"$split_dir/3-argocd-resources.yaml"
kapply -f "$split_dir/1-foundation.yaml" | sed 's/^/  /'
kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null
kapply -f "$split_dir/2-components.yaml" | wc -l | xargs echo "  objects applied:"
wait_argocd_rollout

log "phase 3: bootstrap - probe (kubectl vs argocd-controller field manager)"
yq 'select(.kind == "Namespace")' "$RENDERED/probe/probe.yaml" | kapply -f -
yq 'select(.metadata.name == "probe-kubectl")' "$RENDERED/probe/probe.yaml" \
  | kubectl apply --server-side --field-manager=kubectl -f -
yq 'select(.metadata.name == "probe-argocd")' "$RENDERED/probe/probe.yaml" \
  | kubectl apply --server-side --field-manager=argocd-controller -f -

snapshot before-adoption
dump_specs before-adoption
echo "field managers of ds/cilium before adoption:"
managers ds/cilium kube-system
echo "tracking annotation on ds/cilium before adoption:" \
  "$(kubectl -n kube-system get ds cilium -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}')"

log "phase 4: hand over - apply the AppProject and the argocd Application"
start_apps_watch
kapply -f "$split_dir/3-argocd-resources.yaml" | sed 's/^/  /'
wait_apps "$REV_V1" 600
apps_table

# Longer than one reconcile period (120 s + up to 60 s jitter), with a hard
# refresh in the middle: reconciledAt must move and no new sync may start.
log "phase 4: no OutOfSync loop - watch for ${WATCH_SECONDS}s, hard refresh midway"
reconciled() {
  kubectl -n argocd get applications.argoproj.io -o json \
    | jq -c '[.items[] | {n: .metadata.name, r: .status.reconciledAt}]'
}
history_before=$(kubectl -n argocd get applications.argoproj.io -o json \
  | jq -c '[.items[] | {n: .metadata.name, h: (.status.history // [] | length)}]')
reconciled_before=$(reconciled)
not_synced=0
hard_refreshed=false
watch_end=$((SECONDS + WATCH_SECONDS))
while ((SECONDS < watch_end)); do
  sleep 5
  n=$(kubectl -n argocd get applications.argoproj.io -o json \
    | jq '[.items[] | select(.status.sync.status != "Synced")] | length')
  not_synced=$((not_synced + n))
  if [[ $hard_refreshed == false ]] && ((SECONDS > watch_end - WATCH_SECONDS / 2)); then
    for app in "${APPS[@]}"; do
      kubectl -n argocd annotate applications.argoproj.io "$app" \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    done
    hard_refreshed=true
    echo "hard refresh of all Applications at $(date +%H:%M:%S)"
  fi
done
echo "reconciledAt before: $reconciled_before"
echo "reconciledAt after:  $(reconciled)"
history_after=$(kubectl -n argocd get applications.argoproj.io -o json \
  | jq -c '[.items[] | {n: .metadata.name, h: (.status.history // [] | length)}]')
echo "sync history before: $history_before"
echo "sync history after:  $history_after"
echo "samples not Synced during the watch (every 5 s): $not_synced"
[[ $history_before == "$history_after" ]] || echo "WARNING: new syncs during the watch"

log "phase 4: adoption result"
snapshot after-adoption
compare_snapshots before-adoption after-adoption
dump_specs after-adoption
echo "spec changes of the Deployments (pod template excluded):"
diff "$WORK/snap/before-adoption.specs" "$WORK/snap/after-adoption.specs" \
  | sed 's/^/  /' || true
if diff -q "$WORK/snap/before-adoption.templates" \
  "$WORK/snap/after-adoption.templates" >/dev/null; then
  echo "pod templates of the Deployments: identical"
else
  echo "pod templates of the Deployments: CHANGED"
fi
echo "control: does a metadata-only change bump the generation?"
for w in deploy/coredns ds/kube-proxy-absent ds/cilium; do
  kubectl -n kube-system get "$w" >/dev/null 2>&1 || continue
  g1=$(kubectl -n kube-system get "$w" -o jsonpath='{.metadata.generation}')
  kubectl -n kube-system annotate "$w" exp.invalid/control=1 >/dev/null
  g2=$(kubectl -n kube-system get "$w" -o jsonpath='{.metadata.generation}')
  kubectl -n kube-system annotate "$w" exp.invalid/control- >/dev/null
  echo "  $w: annotation added, generation $g1 -> $g2"
done
# .status.operationState is the last operation only: see show_operations.
echo "what the last sync did, per Application (kind: message):"
kubectl -n argocd get applications.argoproj.io -o json | jq -r '.items[]
  | .metadata.name as $a | (.status.operationState.syncResult.resources // [])
  | map(select(.hookType == null)) | group_by(.kind)[]
  | "  \($a) \(.[0].kind) x\(length): \([.[].message] | unique | join(" | "))"'
echo "tracking method: $(kubectl -n argocd get cm argocd-cm \
  -o jsonpath='{.data.application\.resourceTrackingMethod}')"
tracking_id() { # kubectl get arguments
  kubectl get "$@" \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'
}
echo "ds/cilium: $(tracking_id -n kube-system ds/cilium)"
echo "deploy/argocd-server: $(tracking_id -n argocd deploy/argocd-server)"
echo "sts/argocd-application-controller:" \
  "$(tracking_id -n argocd sts/argocd-application-controller)"
echo "crd/httproutes: $(tracking_id crd/httproutes.gateway.networking.k8s.io)"
echo "crd/applications: $(tracking_id crd/applications.argoproj.io)"
crd_state() { # crd
  kubectl get crd "$1" --show-managed-fields -o json | jq -r '
    "  annotations: \(.metadata.annotations // {} | keys | join(", "))",
    "  labels: \(.metadata.labels // {} | keys | join(", "))",
    (.metadata.managedFields[] | "  manager: \(.manager) \(.operation) \(.time)")'
}
echo "crd/httproutes after adoption:"
crd_state httproutes.gateway.networking.k8s.io
kubectl -n argocd get applications.argoproj.io gateway-api-crds -o json | jq -r '
  .status.resources[] | select(.name == "httproutes.gateway.networking.k8s.io")
  | "  status in the Application: \(.status) \(.health.status // "")"'
echo "field managers of ds/cilium after adoption:"
managers ds/cilium kube-system
echo "pruned or deleted resources reported by the syncs:"
kubectl -n argocd get applications.argoproj.io -o json | jq -r '.items[]
  | .metadata.name as $a | (.status.operationState.syncResult.resources // [])[]
  | select(.status == "Pruned" or (.message // "" | test("prun|delete"; "i")))
  | "  \($a): \(.kind)/\(.name) \(.status) \(.message)"' || true
echo "(end of list)"
echo "hooks run by the last sync of the argocd Application:"
kubectl -n argocd get applications.argoproj.io argocd -o json | jq -r '
  (.status.operationState.syncResult.resources // [])[] | select(.hookType)
  | "  \(.hookType) \(.kind)/\(.name): \(.hookPhase // .status) \(.message // "")"'
echo "(end of list)"

log "phase 5: field removal - git drops key b of both probe ConfigMaps"
yq -i 'del(select(.kind == "ConfigMap") | .data.b)' "$RENDERED/probe/probe.yaml"
cp "$RENDERED/probe/probe.yaml" "$WORK/probe-v2.yaml"
# Same commit: a CRD change, as an upgrade of the Gateway API bundle would do.
yq -i '(select(.kind == "CustomResourceDefinition")
  | .metadata.labels."exp.invalid/rev") = "2"' \
  "$RENDERED/gateway-api-crds/gateway-api-standard-install.yaml"
cp "$RENDERED/gateway-api-crds/gateway-api-standard-install.yaml" "$WORK/gw-v2.yaml"
git_commit_push "probe: drop key b; gateway CRDs: add a label"
refresh_apps
wait_apps "$REV" 300
for cm in probe-kubectl probe-argocd; do
  echo "$cm data: $(kubectl -n probe get cm "$cm" -o jsonpath='{.data}')"
  managers "cm/$cm" probe
done
echo "crd/httproutes after a CRD change in git:"
crd_state httproutes.gateway.networking.k8s.io
echo "  tracking-id: $(tracking_id crd/httproutes.gateway.networking.k8s.io)"
echo "probe app sync status: $(kubectl -n argocd get applications.argoproj.io probe \
  -o jsonpath='{.status.sync.status}')"
# The probe commit does not touch rendered/argocd: did the argocd Application
# sync anyway, and for which resource?
show_argocd_oos "$REV"
kubectl -n argocd get applications.argoproj.io argocd -o json | jq -r '
  "argocd app sync history: \(.status.history // [] | length) entries," +
  " last at \((.status.history // [] | last | .revision // "-")[0:8])"'
# Phase 6 replaces the controller pod: keep its log now.
kubectl -n argocd logs sts/argocd-application-controller >"$WORK/controller-phase5.log" 2>&1 || true
echo "controller log, argocd Application, last refresh and auto-sync lines:"
grep -E 'application=argocd( |$)' "$WORK/controller-phase5.log" \
  | grep -E 'Initiated|Refreshing app status' | grep -v 'controller refresh requested' \
  | sed -E 's/^time="([^"]+)".*msg="([^"]*)".*/\1 \2/' \
  | cut -c1-160 | tail -6 | sed 's/^/  /' || true

log "phase 5b: a CRD removed from git - pruned, orphaned or OutOfSync?"
gateway_crds_in_app() {
  kubectl -n argocd get applications.argoproj.io gateway-api-crds -o json | jq -r '
    .status.resources[]? | select(.kind == "CustomResourceDefinition")
    | "\(.name) \(.status)"' | sort
}
echo "CRDs in the gateway-api-crds Application (name status):"
gateway_crds_in_app | sed 's/^/  /'
echo "live Gateway API CRDs: $(kubectl get crd -o name | grep -c 'gateway\.networking\.k8s\.io$')"
readonly DROPPED_CRD=grpcroutes.gateway.networking.k8s.io
yq -i "del(select(.kind == \"CustomResourceDefinition\" and .metadata.name == \"$DROPPED_CRD\"))" \
  "$RENDERED/gateway-api-crds/gateway-api-standard-install.yaml"
git_commit_push "gateway CRDs: drop $DROPPED_CRD"
refresh_apps
# No wait_apps: an orphaned CRD leaves the Application Synced, a tracked one
# is pruned (prune: true); both end Synced. Wait for the revision only.
for _ in $(seq 1 60); do
  [[ $(kubectl -n argocd get applications.argoproj.io gateway-api-crds \
    -o jsonpath='{.status.sync.revision}') == "$REV" ]] && break
  sleep 5
done
sleep 20
kubectl -n argocd get applications.argoproj.io gateway-api-crds -o json | jq -r '
  "gateway-api-crds: \(.status.sync.status) at \((.status.sync.revision // "-")[0:8])," +
  " last operation \(.status.operationState.phase // "-")"'
if kubectl get crd "$DROPPED_CRD" >/dev/null 2>&1; then
  echo "crd/$DROPPED_CRD: still in the cluster (not pruned)"
  echo "  in the Application: $(gateway_crds_in_app | grep "^$DROPPED_CRD " || echo no)"
else
  echo "crd/$DROPPED_CRD: deleted (pruned)"
fi
kubectl -n argocd get applications.argoproj.io gateway-api-crds -o json | jq -r '
  (.status.operationState.syncResult.resources // [])[]
  | select(.kind == "CustomResourceDefinition" and .status == "Pruned")
  | "  sync result: \(.name) \(.status) \(.message)"'

log "phase 6: value bump - Argo CD upgrades its own configuration"
snapshot before-bump
render "$ARGOCD_FROM" -f "$HERE/values/argocd-bump.yaml"
cp "$WORK/probe-v2.yaml" "$RENDERED/probe/probe.yaml"
cp "$WORK/gw-v2.yaml" "$RENDERED/gateway-api-crds/gateway-api-standard-install.yaml"
git -C "$REPO" diff --stat | tail -3
start_avail_probe bump
git_commit_push "argocd: controller.status.processors 20 -> 10"
refresh_apps
wait_apps "$REV" 600
show_argocd_oos "$REV"
wait_argocd_rollout
sleep 10
stop_avail_probe bump
snapshot after-bump
compare_snapshots before-bump after-bump
echo "argocd-cmd-params-cm controller.status.processors:" \
  "$(kubectl -n argocd get cm argocd-cmd-params-cm \
    -o jsonpath='{.data.controller\.status\.processors}')"
kubectl -n argocd get applications.argoproj.io argocd -o json | jq -r '
  "argocd app last operation: \(.status.operationState.phase)" +
  " - \(.status.operationState.message)" +
  " (started \(.status.operationState.startedAt)," +
  " finished \(.status.operationState.finishedAt))"'
apps_table

log "phase 7: chart upgrade - argo-cd $ARGOCD_FROM -> $ARGOCD_TO"
snapshot before-upgrade
render "$ARGOCD_TO" -f "$HERE/values/argocd-bump.yaml"
cp "$WORK/probe-v2.yaml" "$RENDERED/probe/probe.yaml"
cp "$WORK/gw-v2.yaml" "$RENDERED/gateway-api-crds/gateway-api-standard-install.yaml"
git -C "$REPO" diff --stat | tail -3
start_avail_probe upgrade
git_commit_push "argocd: chart $ARGOCD_FROM -> $ARGOCD_TO"
refresh_apps
wait_apps "$REV" 600
show_argocd_oos "$REV"
wait_argocd_rollout
sleep 10
stop_avail_probe upgrade
snapshot after-upgrade
compare_snapshots before-upgrade after-upgrade
echo "Argo CD images now running:"
kubectl -n argocd get pods -o json | jq -r '[.items[].spec.containers[].image]
  | unique[] | "  \(.)"'
kubectl -n argocd get applications.argoproj.io argocd -o json | jq -r '
  "argocd app last operation: \(.status.operationState.phase)" +
  " - \(.status.operationState.message)"'
apps_table

log "phase 8: what if Terraform re-applies the stale v1 files? (dry-run)"
yq 'select(.kind == "Deployment" and .metadata.name == "argocd-server")' \
  "$WORK/rendered-v1/argocd/manifest.yaml" >"$WORK/stale-server.yaml"
echo "- field manager 'kubectl' (alekc/kubectl kubectl_manifest default), no force-conflicts:"
kubectl apply --server-side --dry-run=server --field-manager=kubectl \
  -f "$WORK/stale-server.yaml" 2>&1 | head -6 | sed 's/^/  /' || true
echo "- field manager 'argocd-controller' (same as Argo CD):"
kubectl apply --server-side --dry-run=server --field-manager=argocd-controller \
  -f "$WORK/stale-server.yaml" -o jsonpath='  accepted, image would become {.spec.template.spec.containers[0].image}{"\n"}' 2>&1 || true

log "result"
apps_table
echo "operations of all Applications (watch):"
show_operations
echo "sync history of the argocd Application:"
kubectl -n argocd get applications.argoproj.io argocd -o json | jq -r '
  .status.history[] | "  #\(.id) rev \(.revision[0:8])" +
  " started \(.deployStartedAt) deployed \(.deployedAt)" +
  " by \(if .initiatedBy.automated then "auto-sync" else .initiatedBy.username end)"'
echo "commits:"
git -C "$REPO" log --format='  %h %s' | sed 's/^/ /'
echo "work dir: $WORK"
