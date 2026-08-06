#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/.build/logi-mouse.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
module_cache="$project_dir/.build/module-cache"
xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
sign_identity="${LOGI_MOUSE_SIGN_IDENTITY:--}"

cd "$project_dir"
mkdir -p "$module_cache"
/usr/bin/env \
  DEVELOPER_DIR="$xcode_developer_dir" \
  CLANG_MODULE_CACHE_PATH="$module_cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
  /usr/bin/xcrun swift build -c release --disable-sandbox

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir"
install -m 755 .build/release/logi-mouse "$macos_dir/logi-mouse"
install -m 644 Resources/Info.plist "$contents_dir/Info.plist"
install -m 644 Resources/AppIcon.icns "$resources_dir/AppIcon.icns"
if [[ "$sign_identity" == "-" ]]; then
  codesign --force --sign - --identifier dev.logi-mouse "$app_dir"
  print -u2 -r -- "Built a local development app with an ad-hoc signature."
else
  codesign \
    --force \
    --sign "$sign_identity" \
    --identifier dev.logi-mouse \
    --options runtime \
    --timestamp \
    "$app_dir"
fi
codesign --verify --deep --strict --verbose=2 "$app_dir"

print -r -- "$app_dir"
