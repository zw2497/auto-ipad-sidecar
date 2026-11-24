#!/bin/zsh
set -eu
cd "${0:A:h:h}"
./build.sh
as_app="$PWD/dist/AutoSidecar.app"
mkdir -p "$as_app/Contents/MacOS" "$as_app/Contents/Resources" bin/swift-cache
cp app/Info.plist "$as_app/Contents/Info.plist"
cp bin/auto-sidecar "$as_app/Contents/Resources/auto-sidecar"
/usr/bin/swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$PWD/bin/swift-cache" -framework SwiftUI -framework AppKit -framework ServiceManagement \
  app/Service.swift app/AutoSidecarApp.swift -o "$as_app/Contents/MacOS/AutoSidecar"
# Ad-hoc signing is for local builds. Set CODESIGN_IDENTITY to a Developer ID for distribution.
/usr/bin/codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}" "$as_app/Contents/Resources/auto-sidecar"
/usr/bin/codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}" "$as_app"
/usr/bin/codesign --verify --deep --strict "$as_app"
print "Built: $as_app"
if [[ ${1:-} == --dmg ]]; then
  as_stage=$(mktemp -d)
  trap 'rm -rf "$as_stage"' EXIT
  ditto "$as_app" "$as_stage/AutoSidecar.app"
  ln -s /Applications "$as_stage/Applications"
  hdiutil create -volname AutoSidecar -srcfolder "$as_stage" -ov -format UDZO "$PWD/dist/AutoSidecar.dmg"
fi
