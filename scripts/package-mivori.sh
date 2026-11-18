#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
built_app="${1:?Pass the path to the Release Mivori.app}"
stage_dir="${2:?Pass an empty stage directory outside any synced folder}"
dmg_path="${3:-}"
signing_id="${MIVORI_SIGN_IDENTITY:--}"

if [[ ! -x "$built_app/Contents/MacOS/Mivori" ]]; then
  echo "Missing the Mivori Release executable: $built_app" >&2
  exit 1
fi

mkdir -p "$stage_dir"
app="$stage_dir/Mivori.app"
if [[ -e "$app" || -L "$app" || ( -n "$dmg_path" && -e "$dmg_path" ) ]]; then
  echo "The staged app or output image already exists." >&2
  exit 1
fi

ditto --noqtn --norsrc "$built_app" "$app"
xattr -cr "$app"
resources="$app/Contents/Resources"
info="$app/Contents/Info.plist"
test "$(plutil -extract CFBundleIdentifier raw "$info")" = "io.macdesk.mivori"
test "$(plutil -extract CFBundleIconFile raw "$info")" = "Mivori.icns"
cmp "$project_root/Brand/Mivori.icns" "$resources/Mivori.icns"
test -f "$resources/default.metallib"
test -x "$resources/Resources/wallpaper-wgpu"
test -x "$resources/wallpaperengine-cli"
test -x "$resources/WaifuXSteamService/arm64/runtime/dotnet"
lipo -verify_arch arm64 "$app/Contents/MacOS/Mivori"

# The package is Apple Silicon. Xcode's upstream folder references also carry Intel copies.
for intel_payload in "$resources"/Resources/*-x86_64* "$resources"/*-x86_64; do
  [[ -f "$intel_payload" ]] && rm "$intel_payload"
done
rm -f "$resources/Resources/wallpaperengine-cli" "$resources/AppIcon.icns"

if [[ -d "$app/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' framework; do
    codesign --force --sign "$signing_id" "$framework"
  done < <(find "$app/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0)
fi

timestamp=(--timestamp=none)
if [[ "$signing_id" != "-" ]]; then
  timestamp+=(--options runtime)
  if [[ "${MIVORI_SECURE_TIMESTAMP:-0}" == "1" ]]; then
    timestamp=(--timestamp --options runtime)
  fi
fi

helper="$app/Contents/Helpers/WaifuXHelper.app"
wallpaper_extension="$app/Contents/PlugIns/WaifuXWallpaperExtension.appex"
screensaver="$resources/Screen Savers/WaifuXScreenSaver.saver"
codesign --force --sign "$signing_id" "$screensaver"
codesign --force --sign "$signing_id" "${timestamp[@]}" \
  --entitlements "$project_root/WaifuXWallpaperExtension/WaifuXWallpaperExtension.entitlements" "$wallpaper_extension"
codesign --force --sign "$signing_id" "${timestamp[@]}" \
  --entitlements "$project_root/BackgroundAgent/BackgroundAgent.entitlements" "$helper"
codesign --force --sign "$signing_id" "${timestamp[@]}" \
  --entitlements "$project_root/WaifuX.entitlements" "$app"
codesign --verify --deep --strict "$app"

if [[ -n "$dmg_path" ]]; then
  ln -s /Applications "$stage_dir/Applications"
  hdiutil create -volname Mivori -srcfolder "$stage_dir" -fs HFS+ -format UDZO "$dmg_path"
  hdiutil verify "$dmg_path"
fi
printf '%s\n' "$app"
