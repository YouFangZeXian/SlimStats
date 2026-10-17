#!/bin/zsh
set -euo pipefail
app_path="${1:-/Applications/SlimStats.app}"
[[ -f "$app_path/Contents/Resources/SlimStats.icns" ]]
# Merging a replacement bundle can leave the directory timestamp unchanged.
# Refresh this app only, so Finder and Dock stop reusing the placeholder icon.
touch "$app_path"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path"
