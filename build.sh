#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
rm -rf SlimStats.app
mkdir -p SlimStats.app/Contents/MacOS SlimStats.app/Contents/Resources
cp Info.plist SlimStats.app/Contents/Info.plist
cp Assets/SlimStats.icns SlimStats.app/Contents/Resources/SlimStats.icns
xcrun swift scripts/prepare-app-icon.swift Assets/SlimStats.iconset/icon_128x128@2x.png SlimStats.app/Contents/Resources/AppIcon.rgba
xcrun swift scripts/prepare-device-artwork.swift SlimStats.app/Contents/Resources
xcrun swiftc -Osize -whole-module-optimization -target arm64-apple-macos14.0 -framework AppKit -framework ServiceManagement -framework IOKit main.swift LightButton.swift AppActions.swift DeviceInfo.swift DiskUsageScanner.swift DiskUsageView.swift -o SlimStats.app/Contents/MacOS/SlimStats
codesign --force --deep -s - SlimStats.app
echo "Built SlimStats.app"
