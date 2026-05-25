# AirDesk Changelog

## Unreleased

- Reduced scroll flicker by avoiding repeated CoreGraphics snapshot frames while ScreenCaptureKit is already producing fresh stream frames.
- Bumped the Mac companion build to `1.2.4 (9)` for the website scroll-flicker hotfix.
- Added a Move to Trash action to the Mac installer cleanup reminder.
- Reduced iOS scroll delay by replacing delayed forced scroll keyframes with coalesced low-latency repaint frames.
- Bumped the Mac companion build to `1.2.4 (8)` for the website scroll-latency hotfix.
- Bumped Mac and iOS app versions to `1.2.4 (7)` for the native streaming stability release.
- Restart ScreenCaptureKit display streams when a per-display stream stops or suspends, reducing black-monitor sessions that previously required reconnecting.
- Mark H.264 keyframes only when the encoded payload contains an IDR recovery frame, so reconnects and monitor switches no longer cache unusable P-frames as keyframes.
- Added iOS decoder recovery and deferred Metal redraw retries so scroll-triggered visual refreshes are requested and drawn even after a decode error or a skipped drawable.
- Added iOS Remote connection mode for Cloudflare Tunnel URLs, including `https://` to `wss://` normalization.
- Renamed the iOS AirDesk connection tab to Local and added a first-time pairing prompt before Local connects without a saved trusted-device token.
- Added Mac menu support to copy the active tunnel URL.
- Added Remote Access warnings on Mac and iOS explaining that free Cloudflare tunnels are best-effort and may have relay, URL, speed, or availability limits.
- Added Mac menu version display, Sparkle in-app updates, and Report Issue action.
- Bumped Mac and iOS app versions to `1.2.0 (3)` so matching installs are visible after the remote-access/update changes.
- Improved native stream recovery after black/stale frames and Mac unlock by forcing fresh current-screen keyframes instead of waiting for the next ScreenCaptureKit frame.
- Improved native input responsiveness by throttling keyboard visual refreshes, reducing per-frame latency UI updates, and refreshing the iOS view after scroll gestures when needed.
- Bumped the Mac companion release to `1.2.3 (6)` for Sparkle in-app update delivery.
- Bumped the Mac app hotfix version to `1.2.1 (4)` so existing `1.2.0` installs can detect it through in-app update.
- Bumped the Mac app update-bootstrap version to `1.2.2 (5)` and replaced the manual installer-download flow with real Sparkle in-app updates.

## 1.1.0

- Added local pairing code and token-backed trusted-device authorization.
- Blocked unpaired sockets from receiving screen, clipboard, permission, and lock-status data.
- Added Mac and iOS diagnostics logging and export.
- Moved wire protocol models into shared `AirDeskProtocol`.
- Hardened keyboard responder activation, scroll delivery, zoom anchor behavior, WebSocket lifecycle, and capture restart handling.
- Added QA checklist, smoke-test script, and release packaging script.
- Added release version/build settings for both Mac and iOS projects.
