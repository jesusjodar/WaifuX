#!/bin/bash
# Build, audit and package the static-only fork. Never installs or launches it.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pkg_arch="${WAIFUX_ARCH:-universal}"
case "$pkg_arch" in
  arm64|x86_64) build_archs="$pkg_arch" ;;
  universal) build_archs="arm64 x86_64" ;;
  *) echo 'WAIFUX_ARCH must be arm64, x86_64 or universal' >&2; exit 1 ;;
esac
output_root="${WAIFUX_OUTPUT_DIR:-$repo_root/build/static-wallhaven}"
mkdir -p "$output_root"
package_work="$(mktemp -d "$output_root/package.XXXXXX")"
# Only this newly-created workspace is removed on failure; previous packages remain.
trap 'rm -rf "$package_work"' EXIT
if [[ -n "${WAIFUX_SOURCE_APP:-}" ]]; then
  source_app="$WAIFUX_SOURCE_APP"
else
  xcodegen generate --spec "$repo_root/project.yml" --project "$repo_root"
  xcodebuild -project "$repo_root/WaifuX.xcodeproj" -scheme WaifuX -configuration Release \
    -derivedDataPath "$package_work/DerivedData" "ARCHS=$build_archs" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO build > "$package_work/build.log" 2>&1 || {
      cp "$package_work/build.log" "$output_root/last-build-failure.log"; exit 1;
    }
  source_app="$package_work/DerivedData/Build/Products/Release/WaifuX.app"
fi
python3 "$repo_root/scripts/verify-project-configuration.py" --app "$source_app" --architectures $build_archs
mkdir -p "$package_work/image"
ditto "$source_app" "$package_work/image/WaifuX.app"
app="$package_work/image/WaifuX.app"
identity="${WAIFUX_SIGN_IDENTITY:--}"
sign_bundle() {
  if [[ "$identity" == '-' ]]; then
    codesign --force --sign - "$@"
  else
    codesign --force --sign "$identity" --timestamp --options runtime "$@"
  fi
}
if [[ "$identity" != '-' ]]; then
  : "${WAIFUX_HELPER_PROFILE:?Developer ID distribution requires the helper provisioning profile}"
  cp "$WAIFUX_HELPER_PROFILE" "$app/Contents/Helpers/WaifuXHelper.app/Contents/embedded.provisionprofile"
fi
# Sparkle contains nested updater apps and XPC services. Sign inside-out before
# signing the helper and host with their minimal retained entitlements.
while IFS= read -r -d '' bundle; do
  sign_bundle --deep "$bundle"
done < <(find "$app/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0)
sign_bundle --entitlements "$repo_root/BackgroundAgent/BackgroundAgent.entitlements" "$app/Contents/Helpers/WaifuXHelper.app"
sign_bundle --entitlements "$repo_root/WaifuX.entitlements" "$app"
python3 "$repo_root/scripts/verify-project-configuration.py" --app "$app" --signed --architectures $build_archs
ln -s /Applications "$package_work/image/Applications"
version="$(tr -d '[:space:]' < "$repo_root/VERSION")"
artifact="WaifuX-Wallhaven-$version-$pkg_arch"
# Unique output names prevent overwriting an existing package with a new build.
release_dir="$(mktemp -d "$output_root/$artifact.XXXXXX")"
ditto -c -k --sequesterRsrc --keepParent "$app" "$release_dir/$artifact.zip"
hdiutil create -volname 'WaifuX Wallhaven' -srcfolder "$package_work/image" -format UDZO "$release_dir/$artifact.dmg"
shasum -a 256 "$release_dir/$artifact.zip" "$release_dir/$artifact.dmg" > "$release_dir/SHA256SUMS"
if [[ "$identity" == '-' ]]; then
  echo 'Ad-hoc signed local build. Developer ID signing and notarization have not been performed.' > "$release_dir/SIGNING.txt"
else
  printf 'Signed with the configured identity. Notarization must be completed before public distribution.\n' > "$release_dir/SIGNING.txt"
fi
printf 'Packaged: %s\n' "$release_dir"
