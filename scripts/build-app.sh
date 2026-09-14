#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$root_dir/dist/Codex Runway.app"

cd "$root_dir"
swift build -c release

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$root_dir/.build/release/CodexRunway" "$app_dir/Contents/MacOS/CodexRunway"
cp "$root_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
icon_work_dir="$(mktemp -d /private/tmp/codex-runway-icons.XXXXXX)"
trap 'rm -rf "$icon_work_dir"' EXIT
swift "$root_dir/scripts/GenerateIcons.swift" "$root_dir/App/Assets/codex-runway-icon.svg" "$icon_work_dir"
iconutil -c icns "$icon_work_dir/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
cp "$icon_work_dir/AccountMark.png" "$icon_work_dir/AccountMark@2x.png" "$icon_work_dir/MenuBarMark.png" "$icon_work_dir/MenuBarMark@2x.png" "$app_dir/Contents/Resources/"
codesign --force --sign - --timestamp=none "$app_dir"

echo "Built $app_dir"
