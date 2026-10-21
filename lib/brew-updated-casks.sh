# shellcheck shell=bash
# shellcheck disable=SC2034 # read by upgrade-brew-aged.sh, which sources this
# auto_updates casks whose own updater is off, so upgrade-brew-aged.sh
# upgrades them, age-gated. Rendered from the `cask` field of the Sparkle
# entries in .chezmoidata/macos.toml, all profiles: a cask that is not
# installed is never outdated. Ghostty's updater is off in its own config.
BREW_UPDATED_CASKS=(appcleaner darkmodebuddy ghostty iina keka monitorcontrol netnewswire sourcetree supremo telegram tunnelblick)
