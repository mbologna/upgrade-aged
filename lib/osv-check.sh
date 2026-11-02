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
# kubectl/kubernetes-cli). Each value was checked against OSV.dev and the
# package's own registry or go.mod: a wrong name never matches, so its
# bypass never fires.
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
  # The jj binary's crate (brew and mise both call the tool jj)
  [jj]="crates.io:jj-cli"
  [just]="crates.io:just"
  [mise]="crates.io:mise"
  [ripgrep]="crates.io:ripgrep"
  [sd]="crates.io:sd"
  [starship]="crates.io:starship"
  [tlrc]="crates.io:tlrc"
  [trippy]="crates.io:trippy"
  [watchexec]="crates.io:watchexec-cli"
  [xh]="crates.io:xh"
  # The yazi binary's crate; the `yazi` crate is an unrelated package
  [yazi]="crates.io:yazi-fm"
  [zellij]="crates.io:zellij"
  [zoxide]="crates.io:zoxide"
  # Go modules
  [age]="Go:filippo.io/age"
  # The module path since 2.72 (go.mod)
  [chezmoi]="Go:chezmoi.io/chezmoi/v2"
  [direnv]="Go:github.com/direnv/direnv/v2"
  # The CLI's module; github.com/docker/docker is the daemon
  [docker]="Go:github.com/docker/cli"
  [fzf]="Go:github.com/junegunn/fzf"
  [gh]="Go:github.com/cli/cli/v2"
  # gitleaks' go.mod still names the old repository
  [gitleaks]="Go:github.com/zricethezav/gitleaks/v8"
  [glab]="Go:gitlab.com/gitlab-org/cli"
  [go]="Go:stdlib"
  # Helm 4; v3 advisories are under helm.sh/helm/v3
  [helm]="Go:helm.sh/helm/v4"
  [k9s]="Go:github.com/derailed/k9s"
  # kubectl's advisories are filed against the kubernetes module, which
  # also covers the server components; k8s.io/kubectl has none
  [kubectl]="Go:k8s.io/kubernetes"
  ["kubernetes-cli"]="Go:k8s.io/kubernetes"
  [lazygit]="Go:github.com/jesseduffield/lazygit"
  [opentofu]="Go:github.com/opentofu/opentofu"
  # Podman 6's module path (go.mod); 5.x was github.com/containers/podman/v5
  [podman]="Go:go.podman.io/podman/v6"
  # The module path since 3.8; the old go.mozilla.org path has only
  # advisories fixed in 3.7.1
  [sops]="Go:github.com/getsops/sops/v3"
  [stern]="Go:github.com/stern/stern"
  [trivy]="Go:github.com/aquasecurity/trivy"
  [yq]="Go:github.com/mikefarah/yq/v4"
  # PyPI (Python)
  # awscli is unmapped: PyPI has only v1, and Homebrew's awscli is v2
  ["azure-cli"]="PyPI:azure-cli"
  ["oci-cli"]="PyPI:oci-cli"
  ["pre-commit"]="PyPI:pre-commit"
  [ruff]="PyPI:ruff"
  [uv]="PyPI:uv"
  # npm
  ["bitwarden-cli"]="npm:@bitwarden/cli"
  # Other
  [maven]="Maven:org.apache.maven:maven-core"
  # node is unmapped: npm:node is a separate npm package that installs
  # Node.js binaries, not Node.js
)

has_vulnerability() {
  local pkg="$1" version="$2"
  local entry="${OSV_PACKAGES[$pkg]:-}"
  [[ -z $entry ]] && return 1
  osv_vulnerable "${entry%%:*}" "${entry#*:}" "$version"
}

# osv_vulnerable <ecosystem> <name> <version>: the query itself, for callers
# that already know the OSV name (a uv tool is a PyPI package by definition,
# so upgrade-uv-tools-aged.sh needs no OSV_PACKAGES entry per tool).
osv_vulnerable() {
  local ecosystem="$1" name="$2" version="$3"
  # jq builds the body so a stray quote in a version can't inject JSON.
  local payload
  payload=$(jq -nc --arg v "$version" --arg n "$name" --arg e "$ecosystem" \
    '{version: $v, package: {name: $n, ecosystem: $e}}') || return 1
  # No Authorization header: OSV.dev is a public API, and the GitHub token
  # github-api.sh uses has no business being sent to a third party.
  local response
  response=$(curl -sf --max-time 10 -X POST "https://api.osv.dev/v1/query" \
    -H "Content-Type: application/json" -d "$payload" 2>/dev/null) || return 1
  jq -e '(.vulns // []) | length > 0' <<<"$response" >/dev/null 2>&1
}
