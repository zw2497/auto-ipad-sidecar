# GitHub distribution

AutoSidecar is distributed directly, not through the Mac App Store. The initial
binary targets Apple Silicon (arm64). The SwiftUI app requires macOS 13+, but the
private Sidecar/virtual-display APIs require actual OS/device compatibility testing.

## Build and verify

```sh
./test.sh
python3 scripts/check-localizations.py
./scripts/build-app.sh --dmg
AUTOSIDECAR_EXPECT_LANGUAGE=en dist/AutoSidecar.app/Contents/MacOS/AutoSidecar --self-test -AppleLanguages '(en)'
AUTOSIDECAR_EXPECT_LANGUAGE=zh-Hans dist/AutoSidecar.app/Contents/MacOS/AutoSidecar --self-test -AppleLanguages '(zh-Hans)'
```

The app follows macOS's preferred application language, with English and Simplified
Chinese resources. Unsupported languages fall back to English. Device names and raw
CLI diagnostic output retain their original language. Do not force a language in the
release app. A user can also set an app language in macOS Language & Region settings.

## Sign and notarize

Create a **Developer ID Application** identity for the paid Developer Program team.
Apple Development and Apple Distribution certificates are not substitutes for direct
Developer ID distribution. Keep certificates with private keys and notarization
credentials out of the repository, disk image, and GitHub assets.

```sh
CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' ./scripts/build-app.sh --dmg
```

The build script signs the CLI and app with hardened runtime, the optional Dock
Apple Events entitlement, and a secure timestamp; it then signs the DMG. Configure
a notarization profile interactively on your own machine (do not paste passwords
into chat or scripts):

```sh
xcrun notarytool store-credentials AutoSidecar
NOTARY_PROFILE=AutoSidecar ./scripts/notarize.sh
```

To resume an interrupted wait without uploading again, use
`NOTARY_PROFILE=AutoSidecar ./scripts/notarize.sh --resume SUBMISSION_ID`.

After successful notarization, stapling, and Gatekeeper assessment, the script
creates a versioned DMG and SHA256SUMS in `dist/release/`. Upload only those final
assets. Stapling changes the DMG, so checksums must be generated afterward.

## Before publishing

- Confirm release notes match actual tested behavior; use a prerelease for initial hardware testing.
- Run the physical-device acceptance cases in `app/TESTING.md`, especially iPad-only quit, wake, migration, and login after restart.
- Check upstream licensing/redistribution permission: the current upstream snapshot has no root LICENSE; its README separately credits third-party API references.
- Keep upstream and third-party credits. Do not add an assumed license to upstream code.
- Create/update a **draft** GitHub release on the fork at the tested commit. Attach the notarized assets and publish only when ready.
