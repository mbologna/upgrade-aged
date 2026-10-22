# shellcheck shell=bash
# Shared OSV.dev vulnerability check for the age-gated upgrade scripts.
# Source it; do not run it.
#
# Usage: has_vulnerability <brew_formula_or_mise_tool> <installed_version>
# Returns 0 if OSV.dev lists a vulnerability for that version, 1 otherwise
# (no CVE, unmapped package, or API failure). Unmapped packages are not
# CVE-bypassed: the age gate applies normally.
#
# OSV_PACKAGES maps a package to "ecosystem:osv_package_name". It is the one
# list for both scripts: where the brew formula and the mise tool are named
# differently, both names are keys (delta/git-delta, dua/dua-cli,
# kubectl/kubernetes-cli).
declare -gA OSV_PACKAGES=(
  # crates.io (Rust)
  [atuin]="crates.io:atuin"
  [bat]="crates.io:bat"
  [delta]="crates.io:git-delta"
  ["git-delta"]="crates.io:git-delta"
  [difftastic]="crates.io:difftastic"
  [dua]="crates.io:dua-cli"
  ["dua-cli"]="crates.io:dua-cli"
  [dust]="crates.io:du-dust"
  [eza]="crates.io:eza"
  [fd]="crates.io:fd-find"
  [grex]="crates.io:grex"
  [hexyl]="crates.io:hexyl"
  [hyperfine]="crates.io:hyperfine"
  [mise]="crates.io:mise"
  [ripgrep]="crates.io:ripgrep"
  [sd]="crates.io:sd"
  [starship]="crates.io:starship"
  [tlrc]="crates.io:tlrc"
  [trippy]="crates.io:trippy"
  [watchexec]="crates.io:watchexec-cli"
  [xh]="crates.io:xh"
  [yazi]="crates.io:yazi"
  [zoxide]="crates.io:zoxide"
  # Go modules
  [age]="Go:filippo.io/age"
  [chezmoi]="Go:github.com/twpayne/chezmoi"
  [fzf]="Go:github.com/junegunn/fzf"
  [gitleaks]="Go:github.com/gitleaks/gitleaks"
  [go]="Go:stdlib"
  [k9s]="Go:github.com/derailed/k9s"
  [kubectl]="Go:k8s.io/kubectl"
  ["kubernetes-cli"]="Go:k8s.io/kubectl"
  # The module path since 3.8; the old go.mozilla.org path has only
  # advisories fixed in 3.7.1
  [sops]="Go:github.com/getsops/sops/v3"
  [trivy]="Go:github.com/aquasecurity/trivy"
  # PyPI (Python)
  ["pre-commit"]="PyPI:pre-commit"
  [ruff]="PyPI:ruff"
  [uv]="PyPI:uv"
  # Other
  [maven]="Maven:org.apache.maven:maven-core"
  # node is unmapped: npm:node is a separate npm package that installs
  # Node.js binaries, not Node.js
)

has_vulnerability() {
  local pkg="$1" version="$2"
  local entry="${OSV_PACKAGES[$pkg]:-}"
  [[ -z $entry ]] && return 1
  # jq builds the body so a stray quote in a version can't inject JSON.
  local payload
  payload=$(jq -nc --arg v "$version" --arg n "${entry#*:}" --arg e "${entry%%:*}" \
    '{version: $v, package: {name: $n, ecosystem: $e}}') || return 1
  # No Authorization header: OSV.dev is a public API, and the GitHub token
  # github-api.sh uses has no business being sent to a third party.
  local response
  response=$(curl -sf --max-time 10 -X POST "https://api.osv.dev/v1/query" \
    -H "Content-Type: application/json" -d "$payload" 2>/dev/null) || return 1
  jq -e '(.vulns // []) | length > 0' <<<"$response" >/dev/null 2>&1
}
