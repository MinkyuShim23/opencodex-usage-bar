#!/bin/bash
# usage-bar 빌드: Sources/main.swift -> build/Usage Bar.app
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$root/build/Usage Bar.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$root/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

swiftc -O \
  -target arm64-apple-macos14.0 \
  -framework AppKit \
  -module-cache-path "$root/build/module-cache" \
  -o "$app/Contents/MacOS/Usage Bar" \
  "$root/Sources/main.swift"

codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "built: $app"
