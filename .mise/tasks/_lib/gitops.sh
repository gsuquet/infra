# shellcheck shell=bash
# Shared helpers of the GitOps tasks (manifests:*, policy:*, schemas:check).
# Not a task: mise only runs executable files, and this one has no shebang.

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _red=$'\033[0;31m' _yellow=$'\033[0;33m' _green=$'\033[0;32m' _reset=$'\033[0m'
else
  _red='' _yellow='' _green='' _reset=''
fi

log_info() { printf '%s[INFO]%s %s\n' "$_green" "$_reset" "$*" >&2; }
log_warn() { printf '%s[WARN]%s %s\n' "$_yellow" "$_reset" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$_red" "$_reset" "$*" >&2; }

# GitOps roots: each holds components/, clusters/<cluster>/ and tenants/.
# testdata/gitops is the fixture that proves the tooling works end to end.
# Override with GITOPS_ROOTS="<dir> <dir>". A missing root is skipped, so the
# tasks pass before gitops/ has its first cluster.
gitops_roots() {
  local root
  for root in ${GITOPS_ROOTS:-gitops testdata/gitops}; do
    [ -d "$root" ] && printf '%s\n' "$root"
  done
  return 0
}

# cluster_files <root>: every <root>/clusters/<cluster>/cluster.yaml, sorted.
cluster_files() {
  [ -d "$1/clusters" ] || return 0
  find "$1/clusters" -mindepth 2 -maxdepth 2 -type f -name cluster.yaml | LC_ALL=C sort
}

# rendered_files <root>: every rendered manifest under <root>, sorted.
rendered_files() {
  [ -d "$1/clusters" ] || return 0
  find "$1/clusters" -type f -path '*/rendered/*' -name '*.yaml' | LC_ALL=C sort
}

# require <command...>: fail early with a hint when a tool is missing.
require() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      log_error "$cmd is not installed. Run 'mise install' (versions are pinned in .mise/config.toml)."
      exit 1
    fi
  done
}
