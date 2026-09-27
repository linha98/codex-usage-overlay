#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/dist/Codex悬浮窗.app"
binary_dir="$app_dir/Contents/MacOS"
resources_dir="$app_dir/Contents/Resources"
icon_source="$project_dir/macos/AppIcon.png"
icon_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/CodexOverlayIcon.XXXXXX")"
iconset_dir="$icon_work_dir/AppIcon.iconset"
trap 'rm -rf "$icon_work_dir"' EXIT

rm -rf "$app_dir"
mkdir -p "$binary_dir" "$resources_dir" "$iconset_dir"
swiftc -O -parse-as-library -framework AppKit -framework ServiceManagement \
  "$project_dir/macos/CodexOverlay.swift" \
  -o "$binary_dir/CodexOverlay"
cp "$project_dir/macos/Info.plist" "$app_dir/Contents/Info.plist"

sips -z 16 16 "$icon_source" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_source" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$icon_source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"

# 固定 designated requirement，避免每次重新编译后辅助功能授权只因二进制哈希变化而失效。
codesign --force --deep --sign - \
  --requirements '=designated => identifier "com.local.codex-usage-overlay"' \
  "$app_dir"
echo "构建完成：$app_dir"
