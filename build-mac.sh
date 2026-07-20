#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/dist/Codex悬浮窗.app"
binary_dir="$app_dir/Contents/MacOS"
resources_dir="$app_dir/Contents/Resources"

rm -rf "$app_dir"
mkdir -p "$binary_dir" "$resources_dir"
swiftc -O -parse-as-library -framework AppKit -framework ServiceManagement \
  "$project_dir/macos/CodexOverlay.swift" \
  -o "$binary_dir/CodexOverlay"
cp "$project_dir/macos/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
echo "构建完成：$app_dir"
