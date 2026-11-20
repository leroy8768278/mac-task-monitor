#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
output_dir="$project_dir/dist"
app="$output_dir/Mac 任务台.app"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.packaging.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

bundle="$staging_dir/Mac 任务台.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Library/LaunchAgents"
cp "$project_dir/Packaging/Info.plist" "$bundle/Contents/Info.plist"
cp "$binary_dir/MacTaskMonitor" "$bundle/Contents/MacOS/MacTaskMonitor"
cp "$project_dir/Packaging/local.mactaskmonitor.watchdog.plist" "$bundle/Contents/Library/LaunchAgents/"

iconset="$staging_dir/AppIcon.iconset"
mkdir -p "$iconset"
swift "$project_dir/Scripts/MakeIcon.swift" "$iconset"
/usr/bin/iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
if [[ -e "$app" ]]; then
    /usr/bin/ditto "$bundle" "$app"
else
    mv "$bundle" "$app"
fi
/usr/bin/codesign --verify --strict "$app"
printf '\n%s\n' "$app"
