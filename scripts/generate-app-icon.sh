#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_svg="$project_dir/Resources/AppIcon.svg"
output_icns="$project_dir/Resources/AppIcon.icns"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/logi-mouse-icon.XXXXXX")"
iconset_dir="$work_dir/AppIcon.iconset"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$iconset_dir"
/usr/bin/qlmanage -t -s 1024 -o "$work_dir" "$source_svg" >/dev/null 2>&1
master_png="$work_dir/AppIcon.svg.png"

if [[ ! -f "$master_png" ]]; then
  print -u2 -r -- "Failed to render $source_svg"
  exit 1
fi

render_size() {
  local pixels="$1"
  local filename="$2"
  /usr/bin/sips -z "$pixels" "$pixels" "$master_png" --out "$iconset_dir/$filename" >/dev/null
}

render_size 16 icon_16x16.png
render_size 32 icon_16x16@2x.png
render_size 32 icon_32x32.png
render_size 64 icon_32x32@2x.png
render_size 128 icon_128x128.png
render_size 256 icon_128x128@2x.png
render_size 256 icon_256x256.png
render_size 512 icon_256x256@2x.png
render_size 512 icon_512x512.png
cp "$master_png" "$iconset_dir/icon_512x512@2x.png"

/usr/bin/iconutil -c icns "$iconset_dir" -o "$output_icns"
print -r -- "$output_icns"
