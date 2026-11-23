# upgrade-aged

Bash scripts that upgrade [Homebrew](https://brew.sh/) and [mise](https://mise.jdx.dev/)
packages, [uv](https://docs.astral.sh/uv/) tools, [VS Code](https://code.visualstudio.com/)
extensions and Mac App Store apps only once their latest release is old enough, 14 days by
default. A package whose installed version has a known vulnerability in [OSV.dev](https://osv.dev/)
is upgraded straight away; OSV.dev has no entries for VS Code extensions or App Store apps, so
they always wait.

For mise the wait itself is mise's own
[`minimum_release_age`](https://mise.jdx.dev/configuration/settings.html) setting; the script
adds the vulnerability exemption and skips tools whose backend publishes no release dates,
which that setting cannot hold back.

The wait is what is now called a *dependency cooldown*. William Woodruff
[explains why it works](https://blog.yossarian.net/2025/11/21/We-should-all-be-using-dependency-cooldowns)
(eight of ten recent supply-chain attacks were caught within a week) and
[answers the usual objections](https://blog.yossarian.net/2025/12/13/cooldowns-redux);
[cooldowns.dev](https://cooldowns.dev/) lists the setting each package manager has for it. These
scripts cover what those settings cannot: Homebrew, VS Code and the Mac App Store, which have
none, a vulnerability exemption, and upgrades that never go backwards.

The reasoning, and how the scripts decide, is in the blog post
[Making Homebrew and mise wait two weeks before they upgrade](https://www.michelebologna.net/2026/homebrew-mise-wait-two-weeks/).

These files are mirrored from my private dotfiles by CI. Fixes are welcome as issues; a pull
request would be overwritten by the next sync, so I apply changes there and they come back here.

## What is in here

| File | What it does |
|---|---|
| `upgrade-brew-aged.sh` | Age-gates Homebrew formulae and casks. Falls back to the newest aged version when the latest is too new, and checks dependencies and dependents before upgrading. |
| `upgrade-mise-aged.sh` | Upgrades mise tools within mise's `minimum_release_age`, adds the vulnerability exemption, and skips tools without release dates. |
| `upgrade-uv-tools-aged.sh` | Upgrades `uv tool install` tools with uv's `--exclude-newer`, adds the vulnerability exemption, and never downgrades a tool already newer than the window. |
| `upgrade-vscode-extensions-aged.sh` | Installs, for each VS Code extension, the newest stable Marketplace release that is old enough, built for your platform and supported by your VS Code. Skips pre-releases and never downgrades. |
| `upgrade-mas-aged.sh` | Upgrades Mac App Store apps with [mas](https://github.com/mas-cli/mas) once the version the App Store serves is old enough, by its release date from the iTunes Lookup API. The App Store serves only its newest version, so a young release waits; there is no vulnerability exemption. |
| `lib/osv-check.sh` | The OSV.dev check (`osv_vulnerable` for a known ecosystem, `has_vulnerability` through the map), and the map from package names to OSV ecosystem names. |
| `lib/github-api.sh` | GitHub API calls for the brew script, cached per run, with rate-limit handling. |
| `lib/brew-updated-casks.sh` | The list of self-updating casks the brew script gates anyway (`BREW_UPDATED_CASKS`). |
| `lib/mise-lock.sh` | Keeps a live `mise.lock` and its [chezmoi](https://www.chezmoi.io/) source copy in step; used by the mise script. |
| `lib/log.sh` | Output helpers. |

## Requirements

- bash 4.3 or later (4.2 for the mise script). macOS ships bash 3.2, so install a newer one with `brew install bash`. The
  scripts use `#!/usr/bin/env bash`, so the Homebrew bash has to come first on `PATH`.
- `curl` and [jq](https://jqlang.org/).
- For mise, a version with the `minimum_release_age` setting, set in your mise config
  (`minimum_release_age = "14d"`). The script refuses to run without it.
- For uv tools, uv 0.9.17 or later, which takes a relative `--exclude-newer` (`"14 days"`).
- For VS Code extensions, the `code` command on `PATH`. Set `"extensions.autoUpdate": "off"` in
  VS Code, or it updates extensions past the gate itself. The Update button in the Extensions
  view still installs the newest release.
- For Mac App Store apps, [mas](https://github.com/mas-cli/mas), signed in to the App Store.
  Turn off automatic app updates in the App Store settings, or it updates apps past the gate
  itself.
- `python3`, for `upgrade-brew-aged.sh` only (it reads version fields out of formula files).
- Homebrew or mise, depending on the script.

## Install

Copy the scripts and the `lib/` directory together; the scripts look for `lib/` next to
themselves.

```bash
git clone https://github.com/mbologna/upgrade-aged.git
mkdir -p ~/.local/bin
cp -R upgrade-aged/upgrade-*-aged.sh upgrade-aged/lib ~/.local/bin/
```

Run each script with `--dry-run` first. It prints what it would upgrade, hold back or skip,
and why, without changing anything.

## Configuration

The scripts read environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `MIN_AGE_DAYS` | `14` | Brew, uv tools, VS Code extensions and App Store apps: how many days old a release must be before it is installed. For mise, set `minimum_release_age` instead. |
| `GITHUB_TOKEN` | the `gh` login | Brew only: a GitHub token. When unset, the script asks the [GitHub CLI](https://cli.github.com/) for its login. Without either, the GitHub API allows 60 requests an hour, which a normal week of updates uses up; with one, 5000. It needs no permissions. |
| `MAX_COMMITS_BACK` | `5` | Brew only: how many past commits of a formula to search for an aged version. |
| `MISE_LOCK_AUTOCOMMIT` | `1` | mise only: commit `mise.lock` after syncing it back to a [chezmoi](https://www.chezmoi.io/) source directory. Does nothing without chezmoi. |
| `MISE_LOCK_AUTOPUSH` | `0` | mise only: push after that commit. |

Some settings are lists in the scripts, and you will want to edit them for your machine:

- `BREW_UPDATED_CASKS` in `lib/brew-updated-casks.sh`: casks that update themselves, which you want
  gated anyway. Turn each app's own updater off first, or it will keep updating past the gate.
- `OSV_PACKAGES` in `lib/osv-check.sh`: the OSV ecosystem name of each package. A package that is
  not listed gets no vulnerability exemption and waits like any other.

## Running from topgrade

With [topgrade](https://github.com/topgrade-rs/topgrade), disable its own brew, mise, uv,
vscode and mas steps, or they will install everything the scripts held back:

```toml
[misc]
disable = ["brew_formula", "brew_cask", "mise", "uv", "vscode", "mas"]

[commands]
"Homebrew (aged)" = "~/.local/bin/upgrade-brew-aged.sh"
"mise (aged)" = "~/.local/bin/upgrade-mise-aged.sh"
"uv tools (aged)" = "~/.local/bin/upgrade-uv-tools-aged.sh"
"VS Code extensions (aged)" = "~/.local/bin/upgrade-vscode-extensions-aged.sh"
"Mac App Store (aged)" = "~/.local/bin/upgrade-mas-aged.sh"
```

## Why not an existing tool

Some package managers now have an age gate of their own. None of them does what these scripts do:

- mise's [`minimum_release_age`](https://mise.jdx.dev/configuration/settings.html) has no
  vulnerability exemption, only warns about tools without release dates instead of skipping
  them, and does not sync `mise.lock` back
  ([#22](https://github.com/mbologna/upgrade-aged/issues/22)).
- uv's `exclude-newer` has no vulnerability exemption.
- Homebrew declined an age gate
  ([Homebrew/brew#22659](https://github.com/Homebrew/brew/issues/22659), closed as not
  planned), and has no fallback to an older formula version that is old enough.
- mas and topgrade have no age gate
  ([topgrade-rs/topgrade#1890](https://github.com/topgrade-rs/topgrade/issues/1890), tracked in
  [#21](https://github.com/mbologna/upgrade-aged/issues/21)).
- VS Code's `extensions.autoUpdateDelay` never picks an older version that is old enough,
  starves extensions that publish often, and lets trusted publishers skip the delay
  ([microsoft/vscode#342090](https://github.com/microsoft/vscode/issues/342090), tracked in
  [#20](https://github.com/mbologna/upgrade-aged/issues/20)).

Checked 2026-11-23.

## Versioning

This repository has no releases: `main` is what you clone, and CI syncs it from my dotfiles
whenever a mirrored script changes there. See the
[versioning standard](https://github.com/mbologna/.github/blob/main/VERSIONING.md).

## License

[MIT](LICENSE)
