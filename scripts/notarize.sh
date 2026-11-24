#!/bin/zsh
# Credentials must already be stored using notarytool store-credentials.
# This script never accepts passwords or uploads to GitHub.
set -eu
cd "${0:A:h:h}"
if [[ -z ${NOTARY_PROFILE:-} ]]; then
  print -u2 'Set NOTARY_PROFILE to your notarytool Keychain profile.'; exit 1
fi
as_dmg="$PWD/dist/AutoSidecar.dmg"
as_app="$PWD/dist/AutoSidecar.app"
[[ -f "$as_dmg" ]] || { print -u2 'Build the signed DMG first.'; exit 1; }
# Fail closed: an Apple Development or ad-hoc build is not a distribution build.
for as_item in "$as_app/Contents/Resources/auto-sidecar" "$as_app" "$as_dmg"; do
  as_info=$(/usr/bin/codesign -dvv "$as_item" 2>&1)
  [[ "$as_info" == *'Authority=Developer ID Application:'* && "$as_info" == *'Timestamp='* ]] || {
    print -u2 "Missing Developer ID signature or timestamp: $as_item"; exit 1
  }
done
/usr/bin/codesign --verify --deep --strict "$as_app"
if [[ ${1:-} == --resume && -n ${2:-} && $# == 2 ]]; then
  xcrun notarytool wait "$2" --keychain-profile "$NOTARY_PROFILE" --timeout 30m
elif (( $# == 0 )); then
  xcrun notarytool submit "$as_dmg" --keychain-profile "$NOTARY_PROFILE" --wait
else
  print -u2 'Usage: notarize.sh [--resume SUBMISSION_ID]'; exit 1
fi
# Stapling fails if notarization was rejected; no rejected artifact reaches the release folder.
xcrun stapler staple "$as_dmg"
xcrun stapler validate "$as_dmg"
spctl --assess --type open --context context:primary-signature --verbose "$as_dmg"
as_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$as_app/Contents/Info.plist")
as_release="$PWD/dist/release"
mkdir -p "$as_release"
as_name="AutoSidecar-${as_version}-$(uname -m).dmg"
cp "$as_dmg" "$as_release/$as_name"
(cd "$as_release" && shasum -a 256 "$as_name" > SHA256SUMS)
print "Notarized release assets: $as_release"
