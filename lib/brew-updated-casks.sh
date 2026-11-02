# shellcheck shell=bash
# shellcheck disable=SC2034 # read by upgrade-brew-aged.sh, which sources this
# auto_updates casks whose own updater is off, so upgrade-brew-aged.sh
# upgrades them, age-gated. Rendered from the `cask` field of the Sparkle
# entries in .chezmoidata/macos.toml, plus the casks whose updater is off in
# their own config, all profiles: a cask that is not installed is never
# outdated.
#   dbeaver-community  ui.auto.update.check=false in its core prefs
#                      (private_Library/DBeaverData)
#   gcloud-cli         topgrade's gcloud step (`gcloud components update`)
#                      is off, so nothing else updates the SDK
#   ghostty            auto-update = off in its config
#   goland, intellij-idea, pycharm
#                      ide.no.platform.update in ~/idea.properties
#   visual-studio-code "update.mode": "none" (vscode/settings.jsonc)
#   zed                "auto_update": false (zed/settings.jsonc)
BREW_UPDATED_CASKS=(appcleaner darkmodebuddy dbeaver-community gcloud-cli ghostty goland iina intellij-idea keepingyouawake keka monitorcontrol netnewswire pycharm sourcetree supremo telegram tunnelblick visual-studio-code zed)
