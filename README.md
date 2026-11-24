# AutoSidecar

Plug in your iPad to use it as a Mac display. AutoSidecar starts Sidecar on USB
connection, reconnects after Mac or screen wake, and runs automatically after login.

- **At your desk:** add the iPad as an extra screen alongside any other monitor.
- **Without a monitor:** use the iPad as your Mac's desktop, including on a Mac mini.
- **Between setups:** automatically switch between extended and iPad-only use.

## Install

You'll need [Sidecar-compatible devices](https://support.apple.com/en-us/102597),
a USB data cable, and Apple's Command Line Tools (`xcode-select --install`).

In Terminal:

```sh
git clone https://github.com/koonweee/auto-ipad-sidecar.git
cd auto-ipad-sidecar
./auto-sidecar install
```

The installer builds the utility, asks you to select your iPad, and tests the
connection. Confirm the desktop appears on the correct iPad to finish. A physical
monitor makes initial setup easier.

That's it: AutoSidecar starts after each login and connects your enrolled iPad
when you plug it in. `setup` can enroll separately; `install` enables the automation.
After Mac sleep or display sleep, it waits five seconds for services to settle
and retries Sidecar if the enrolled iPad is still connected by USB. This also
covers returning to screens that turned off while the Mac stayed awake, such as
after locking. Locking alone is not a wake trigger. An active connection is preserved.

### Unattended boot

- Install and enroll first, then enable **System Settings → Users & Groups →
  Automatically log in as** for the account running AutoSidecar.
- Automatic login requires FileVault to be off and allows anyone with physical
  access to boot into that account. See [Apple's automatic login guide](https://support.apple.com/en-us/102316)
  for requirements and restrictions.
- Leave the enrolled iPad connected by USB. AutoSidecar detects it after login;
  it cannot display FileVault unlock or the login screen.
- Test a restart before relying on a monitor-free setup. If Sidecar does not
  connect, unlock the iPad and reconnect the cable.

## Preferences

```sh
./auto-sidecar configure
```

- **With other displays:** extend (default), mirror, or preserve the existing layout.
- **iPad-only desktop:** adjust resolution and display settings.
- **Dock profiles:** optionally set size and magnification for each setup.
  Dock settings are untouched by default and restored after an active session ends.

Changes apply without restarting; resolution changes wait until the next connection.

### Choosing a resolution

- Lower desktop resolution makes text larger; higher resolution fits more content.
- Keep the aspect ratio of a working native Sidecar resolution to avoid black bars.
  Use its usable display area, which can change with Sidecar's sidebar or Touch Bar.
- Prefer HiDPI for text clarity. More rendered pixels cost more graphics work and
  do not always look sharper after scaling to the iPad.
- Logical dimensions describe workspace size; 1280 × 840 at 2× HiDPI renders
  2560 × 1680 pixels. Enter backing pixels (2560 × 1680 in this example) in
  `configure`; HiDPI requires even dimensions.

## Useful commands

```sh
./auto-sidecar status
./auto-sidecar doctor
./auto-sidecar connect
./auto-sidecar disconnect
./auto-sidecar install           # Update, keeping preferences
./auto-sidecar uninstall         # Remove; keep pairing and logs
./auto-sidecar uninstall --purge # Remove pairing and logs too
```

Outside the project directory, use the installed command:

```sh
"$HOME/Library/Application Support/AutoSidecar/auto-sidecar" configure
```

## Things to know

- Starts **after login**, not at FileVault unlock or the login screen.
- Unplugging USB may leave Sidecar connected over Wi-Fi.
- If connection retries fail, unlock the iPad and reconnect the cable.
- Stopping or uninstalling can end an iPad-only session.
- Uses private macOS APIs; OS updates may break compatibility. Tested on macOS
  27.0.1 / Apple M4. HiDPI output and refresh rates above 60 Hz need further validation.

- **Logs:** `~/Library/Logs/AutoSidecar/events.log`
- **Configuration:** `~/Library/Application Support/AutoSidecar/config.plist`

## Technical notes

- Native, event-driven utility and per-user LaunchAgent; no idle polling.
- USB enrollment identifies one iPad.
- A temporary virtual display supports iPad-only use; macOS handles rendering
  and streaming.
- Optional Dock profiles use System Events and may require Automation permission.
- Use `config show`, `config validate`, and `reload` for manual preference edits.
- Run `./test.sh` for automated tests; hardware behavior requires device testing.

## Dependencies and credits

Uses Apple's system frameworks, SidecarCore, command-line tools and Clang.
No third-party package or helper executable is bundled.

- [SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher), Jovany Ocasio,
  © 2023 ([MIT](https://github.com/Ocasio-J/SidecarLauncher/blob/main/LICENSE)):
  SidecarCore API reference.
- [Fuzzy-Team/virtual-monitor-helper](https://github.com/Fuzzy-Team/virtual-monitor-helper):
  virtual-display API declaration reference.

## Minimal macOS app (SwiftUI)

Build the menu-bar app and drag-to-install disk image (macOS 13+, Xcode Swift toolchain):

```sh
./scripts/build-app.sh --dmg
```

Open `dist/AutoSidecar.dmg`, drag **AutoSidecar** into **Applications**, then open it.
The menu shows the actual owned watcher process and the system login-item status.
Settings provide device enrollment, backing-pixel dimensions, HiDPI, display layout,
and optional Dock profiles and refresh rate. Refresh rates above 60 Hz are experimental;
a configured virtual-display rate does not prove Sidecar's delivered frame rate.

The app bundles the existing Objective-C CLI. It owns one `watch` child process;
closing Settings keeps it alive, while **Quit AutoSidecar** disconnects the current
Sidecar session, stops the watcher, restores optional Dock overrides, and releases
its virtual display. An iPad-only desktop requires confirmation before quitting.
The login-item preference is retained when quitting. Login startup uses Apple's
`SMAppService.mainApp`, and any pending approval is shown in Settings.

On first normal launch, an installed legacy `local.auto-sidecar` LaunchAgent is
unloaded and its plist backed up under Application Support. The app then registers
itself for login if that legacy plist existed. This ownership transfer can briefly
interrupt an existing headless session. CLI commands remain available, but do not
run the legacy `install` command while using the GUI; it would restore the old
LaunchAgent. New CLI watchers use an exclusive per-config lock to prevent duplication.

Pairing tests use a temporary configuration without replacing the saved pairing.
Select the USB iPad and matching Sidecar target, test, then confirm the actual screen.
Saving a new pairing briefly recreates the service. Cancelling restores the saved
service. Logs are in `~/Library/Logs/AutoSidecar/gui-service.log`.

For development without touching pairing, devices, or login items:

```sh
dist/AutoSidecar.app/Contents/MacOS/AutoSidecar --preview
dist/AutoSidecar.app/Contents/MacOS/AutoSidecar --self-test
dist/AutoSidecar.app/Contents/MacOS/AutoSidecar --render-preview /tmp/settings.png
```

The self-test checks configuration preservation against the real core and service
lifecycle against a fake executable. Real USB enrollment, Sidecar, Dock Automation,
and login after reboot require hardware/system testing; preview mode does not prove
them. Build output is ad-hoc signed by default for local development, not notarized.
Use `CODESIGN_IDENTITY='Developer ID Application: …' ./scripts/build-app.sh --dmg`
with your own identity for signed builds; notarization is a separate distribution step.
