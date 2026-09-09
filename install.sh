#!/bin/bash
# Build, install into /Applications, and start at login.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_path="/Applications/Usage Bar.app"
label="com.minkyushim.usage-bar"
agent="$HOME/Library/LaunchAgents/$label.plist"

"$root/build.sh"

rm -rf "$app_path"
cp -R "$root/build/Usage Bar.app" "$app_path"

# The plist has to carry an absolute path, so it is generated rather than checked in.
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__APP_PATH__|$app_path|" "$root/launchagent/$label.plist.template" > "$agent"

launchctl unload -w "$agent" 2>/dev/null || true
launchctl load -w "$agent"

echo "installed: $app_path"
echo "login item: $agent"
