#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
app="$root/build/RMV Float.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -framework AppKit -framework WebKit "$root/Sources/HomepageStore.swift" "$root/Sources/NavigationRouting.swift" "$root/Sources/Zoom.swift" "$root/Sources/AppDelegate.swift" -o "$app/Contents/MacOS/RMV Float"
cp "$root/Info.plist" "$app/Contents/Info.plist"
echo "Built $app"
