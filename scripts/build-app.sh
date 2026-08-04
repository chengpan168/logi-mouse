#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/.build/logi-mouse.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
module_cache="$project_dir/.build/module-cache"
xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"

cd "$project_dir"
mkdir -p "$module_cache"
/usr/bin/env \
  DEVELOPER_DIR="$xcode_developer_dir" \
  CLANG_MODULE_CACHE_PATH="$module_cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
  /usr/bin/xcrun swift build -c release --disable-sandbox

rm -rf "$app_dir"
mkdir -p "$macos_dir"
install -m 755 .build/release/logi-mouse "$macos_dir/logi-mouse"
install -m 644 Resources/Info.plist "$contents_dir/Info.plist"
codesign --force --sign - --identifier dev.logi-mouse "$app_dir"
codesign --verify --deep --strict "$app_dir"

print -r -- "$app_dir"
