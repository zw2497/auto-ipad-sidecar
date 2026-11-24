# GUI validation

Run `./test.sh`, then `./scripts/build-app.sh --dmg` and the app's `--self-test`.
Use `--preview` for UI work without changing the running Sidecar installation.

Hardware acceptance (not covered by fixtures):

- Install the app in Applications; legacy LaunchAgent hands ownership to the app.
- Existing pairing loads; USB plug and wake start Sidecar with no other display.
- Menu reflects an owned live process, process failure, and actual login-item status.
- Enable/disable login startup, approve in System Settings if requested, and verify next login.
- Pair a device, confirm the intended screen, and check persistence on relaunch.
- Cancel or fail replacement pairing; original binding and service recover.
- Apply layout and Dock settings; the owned process acknowledges SIGHUP reload.
- Apply dimensions/HiDPI/rate; current display stays alive until the next connection.
- Close settings; service remains. Quit with iPad as sole display; cancel preserves it.
- Confirm Quit; Sidecar disconnects, watcher exits, Dock restores, helper vanishes.
- Reopen after Quit; service returns without duplicate watchers. GUI crash also stops its child.

A mode reporting 120 Hz or a browser reporting 120 fps does not verify the delivered
Sidecar frame rate. No physical-device behavior should be inferred from a passing fixture.
