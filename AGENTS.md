# AirDesk Project Guide

## Project Shape

- AirDesk is a Mac + iOS remote desktop app.
- The Mac companion app is a macOS menu bar app in `AirDesk-Mac/`.
- The iOS client is a SwiftUI app in `AirDesk-iOS/`.
- Shared wire protocol models live in `Shared/AirDeskProtocol/`.
- The bundled VNC compatibility dependency lives in `Vendor/royalvnc/`.

## Core Behavior

- Native AirDesk sharing uses a WebSocket server on port `7890`, Bonjour `_airdesk._tcp.` discovery, pairing codes, trusted-device HMAC reconnects, ScreenCaptureKit capture, H.264 encoding, and CGEvent input injection.
- VNC compatibility mode uses macOS Screen Sharing or another VNC server, usually on port `5900`.
- Remote access uses Cloudflare Tunnel via `cloudflared` to expose the Mac WebSocket server without router port forwarding.
- Mac update checks use GitHub Releases for `helloxtech/MacRemoteDesktop`; release assets should include a Mac `.dmg` or `.zip` for in-app download.
- Keep local AirDesk, remote AirDesk, and VNC connection paths distinct in UI copy and diagnostics.

## Development Notes

- Follow the existing SwiftUI/AppKit style and keep changes scoped to the relevant Mac, iOS, shared protocol, QA, and docs files.
- Update `CHANGELOG.md` for user-facing behavior changes.
- Keep QA notes in `QA/` aligned with new connection modes.
- Do not commit credentials, tokens, generated tunnel URLs, or private device identifiers.

## Verification

- Prefer focused builds:
  - Mac: `xcodebuild -project AirDesk-Mac/AirDesk-Mac.xcodeproj -scheme AirDesk -configuration Release -derivedDataPath build/AirDesk-Mac build`
  - iOS generic: `xcodebuild -project AirDesk-iOS/AirDesk.xcodeproj -scheme AirDesk -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/AirDesk-iOS-generic CODE_SIGNING_ALLOWED=NO build`
- When Xcode project files need regeneration, use XcodeGen from each app folder if available.
