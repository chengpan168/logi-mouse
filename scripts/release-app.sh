#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/.build/logi-mouse.app"
notarization_archive="$project_dir/.build/logi-mouse-notarization.zip"
release_archive="$project_dir/.build/logi-mouse-notarized.zip"
manifest="$project_dir/.build/logi-mouse-release-manifest.txt"
developer_id="${LOGI_MOUSE_DEVELOPER_ID_APPLICATION:?Set LOGI_MOUSE_DEVELOPER_ID_APPLICATION to the Developer ID Application identity.}"
notary_profile="${LOGI_MOUSE_NOTARY_PROFILE:?Set LOGI_MOUSE_NOTARY_PROFILE to a notarytool keychain profile.}"

cd "$project_dir"
if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 -r -- "Refusing to release from a dirty worktree. Commit or stash all changes first."
  exit 1
fi

LOGI_MOUSE_SIGN_IDENTITY="$developer_id" "$project_dir/scripts/build-app.sh"

rm -f "$notarization_archive" "$release_archive" "$manifest"
/usr/bin/ditto -c -k --keepParent "$app_dir" "$notarization_archive"
/usr/bin/xcrun notarytool submit \
  "$notarization_archive" \
  --keychain-profile "$notary_profile" \
  --wait
/usr/bin/xcrun stapler staple "$app_dir"
/usr/bin/xcrun stapler validate "$app_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app_dir"

/usr/bin/ditto -c -k --keepParent "$app_dir" "$release_archive"
commit="$(git rev-parse HEAD)"
checksum="$(/usr/bin/shasum -a 256 "$release_archive" | /usr/bin/awk '{print $1}')"
{
  print -r -- "commit=$commit"
  print -r -- "artifact=${release_archive:t}"
  print -r -- "sha256=$checksum"
  print -r -- "signing_identity=$developer_id"
} > "$manifest"

print -r -- "$release_archive"
print -r -- "$manifest"
