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
codesign --force --sign - --timestamp=none "$app_dir"

echo "Built $app_dir"
