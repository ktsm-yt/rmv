#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
binary="$(mktemp -d)/homepage-store-tests"
trap 'rm -rf "${binary:h}"' EXIT
xcrun swiftc "$root/Sources/HomepageStore.swift" "$root/Sources/NavigationRouting.swift" "$root/Sources/Zoom.swift" "$root/Sources/FloatSettings.swift" "$root/Sources/ShortcutStore.swift" "$root/Tests/HomepageStoreTests.swift" -o "$binary"
"$binary"
