# AirDesk QA Checklist

Run this checklist before handing a build to a real user.

## Build

- Regenerate projects with `xcodegen` from `AirDesk-Mac` and `AirDesk-iOS`.
- Run `scripts/qa_smoke.sh`.
- For device install coverage, run `IOS_DEVICE_ID=<device-udid> scripts/qa_smoke.sh` or `scripts/install_ios_device.sh <device-udid>`.
- Confirm Mac app launches from `/Applications/AirDesk.app`.
- Confirm iPhone app installs on a physical device.

## Pairing And Security

- Start sharing on the Mac and verify the menu shows a six-digit pairing code.
- Try connecting from iPhone with no code. Expected: connection is rejected with pairing-required message.
- Try connecting with a wrong code. Expected: connection is rejected.
- Try connecting with the correct code. Expected: client pairs and screen info appears.
- Disconnect and reconnect without entering a code. Expected: trusted device connects.
- Reset trusted devices from the Mac menu and try reconnecting without a code. Expected: copied client IDs or stale auth tokens are rejected, and the same iPhone requires a new code.

## Permissions

- Revoke Screen Recording. Expected: Mac blocks sharing and shows setup guidance.
- Revoke Accessibility. Expected: viewing works, input is disabled, iPhone shows permission banner.
- Re-enable permissions and relaunch Mac app. Expected: view and control both work.

## Connection Stability

- Connect/disconnect 20 times on the same network.
- Put Mac to sleep, wake it, and reconnect.
- Lock and unlock the Mac while connected.
- Toggle Wi-Fi on the iPhone and verify reconnect behavior is understandable.
- Leave the screen idle for five minutes. Expected: no flashing or refresh storm.

## Input

- Control mode: tap, double tap, long press/right click.
- Control mode: drag to move the local canvas.
- Scroll mode: repeated single-finger scroll gestures.
- Two-finger scroll in both modes.
- Pinch zoom in/out and drag the zoomed canvas freely.
- Keyboard button opens promptly and can be toggled repeatedly.
- Arrow, Enter, Esc, Tab, and modifier buttons send correct key events.
- Clipboard push from iPhone to Mac works.

## Diagnostics

- Export diagnostics from the Mac menu.
- Export diagnostics from the iPhone connection screen.
- Export diagnostics while connected from the iPhone remote toolbar.
- Confirm exports include version, device/OS, permissions, and recent events.

## Mac Updates And Support

- Confirm the Mac menu shows the installed version/build.
- Confirm "Check for Updates..." reaches GitHub Releases and reports up-to-date, update-available, or check-failed states clearly.
- When a newer release is available, confirm a purple dot appears on the AirDesk menu bar icon.
- Confirm the in-app update item downloads the latest DMG or ZIP release asset to Downloads and offers to open it or show it in Finder.
- Confirm "Report Issue..." opens a GitHub issue form with AirDesk version and macOS details.

## Release Packaging

- Run `scripts/package_release.sh`.
- Confirm `dist/AirDesk.app`, `dist/AirDesk.zip`, and `dist/AirDesk.dmg` exist.
- Confirm `dist/AirDesk.app/Contents/MacOS/cloudflared` exists and runs `--version`.
- If Developer ID credentials are configured, confirm notarization succeeds.
- Confirm `dist/AirDesk.zip` is created after app notarization when Developer ID credentials are configured.
- Install from the DMG and verify the app runs from Applications.
