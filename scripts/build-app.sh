#!/bin/zsh
set -eu
cd "${0:A:h:h}"
./build.sh
as_app="$PWD/dist/AutoSidecar.app"
mkdir -p "$as_app/Contents/MacOS" "$as_app/Contents/Resources" bin/swift-cache
cp app/Info.plist "$as_app/Contents/Info.plist"
ditto app/Resources "$as_app/Contents/Resources"
/usr/bin/swift -module-cache-path "$PWD/bin/swift-cache" scripts/build-icon.swift \
  "$PWD/app/Artwork/logo-concept.png" "$PWD/bin/AutoSidecar.iconset"
/usr/bin/iconutil -c icns "$PWD/bin/AutoSidecar.iconset" -o "$as_app/Contents/Resources/AutoSidecar.icns"
cp bin/auto-sidecar "$as_app/Contents/Resources/auto-sidecar"
/usr/bin/swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$PWD/bin/swift-cache" -framework SwiftUI -framework AppKit -framework ServiceManagement \
  app/Service.swift app/AutoSidecarApp.swift -o "$as_app/Contents/MacOS/AutoSidecar"
# Developer ID builds need secure timestamps; local previews use ad-hoc signing.
as_identity="${CODESIGN_IDENTITY:--}"
as_sign_args=(--force --options runtime --entitlements app/AutoSidecar.entitlements --sign "$as_identity")
if [[ "$as_identity" != - ]]; then as_sign_args+=(--timestamp); fi
/usr/bin/codesign "${as_sign_args[@]}" "$as_app/Contents/Resources/auto-sidecar"
/usr/bin/codesign "${as_sign_args[@]}" "$as_app"
/usr/bin/codesign --verify --deep --strict "$as_app"
print "Built: $as_app"
if [[ ${1:-} == --dmg ]]; then
  as_stage=$(mktemp -d)
  trap 'rm -rf "$as_stage"' EXIT
  ditto "$as_app" "$as_stage/AutoSidecar.app"
  ln -s /Applications "$as_stage/Applications"
  hdiutil create -volname AutoSidecar -srcfolder "$as_stage" -ov -format UDZO "$PWD/dist/AutoSidecar.dmg"
  if [[ "$as_identity" != - ]]; then
    /usr/bin/codesign --force --timestamp --sign "$as_identity" "$PWD/dist/AutoSidecar.dmg"
  fi
fi
