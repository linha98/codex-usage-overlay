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
# 固定 designated requirement，避免每次重新编译后辅助功能授权只因二进制哈希变化而失效。
codesign --force --deep --sign - \
  --requirements '=designated => identifier "com.local.codex-usage-overlay"' \
  "$app_dir"
echo "构建完成：$app_dir"
