# AirDesk

**Remote Desktop for Mac — native iOS app with direct touch control.**

> Control your Mac from iPhone or iPad over local Wi-Fi. Tap exactly where you want to click. Swipe between monitors. Auto-discovers your Mac via Bonjour. Built with Swift, ScreenCaptureKit, and Metal.

---

## Why AirDesk?

Existing VNC apps on iOS have three major problems:
1. **Cursor mode** — you drag a cursor instead of tapping directly
2. **Combined monitors** — all displays stitched into one wide, hard-to-navigate view
3. **Poor UX** — designed for mouse users, not touch

AirDesk fixes all three.

---

## Architecture

```
AirDesk-Mac/          macOS 13+ menu bar companion app
├── ScreenCaptureKit  per-display screen capture at 30fps
├── VideoToolbox      H.264 hardware encoding
├── NWListener        WebSocket server on port 7890
├── CGEvent           mouse + keyboard injection
└── Bonjour           _airdesk._tcp. local discovery

AirDesk-iOS/          iOS 16+ native SwiftUI app
├── NetServiceBrowser Bonjour Mac discovery
├── URLSession WS     WebSocket client
├── VideoToolbox      H.264 hardware decoding
├── Metal / CIContext GPU-accelerated frame rendering
└── UIKit Gestures    direct touch → mouse mapping

Cloudflare/
├── landing-page/     Cloudflare Pages static site
└── worker/           Cloudflare Workers (V2 relay)
```

---

## Protocol

### Text frames (JSON)

**iOS → Mac:**
```json
{ "type": "connect", "clientName": "iPhone", "clientVersion": "1.0" }
{ "type": "request_stream", "displayIndex": 0, "fps": 30, "quality": "high" }
{ "type": "mouse", "x": 0.5, "y": 0.3, "action": "click", "displayIndex": 0 }
{ "type": "key", "keyCode": 0, "modifiers": ["cmd"], "action": "down" }
```

**Mac → iOS:**
```json
{ "type": "screen_info", "monitors": [{ "id": 0, "width": 2560, "height": 1600, "scaleFactor": 2.0, "name": "Built-in Display" }] }
```

### Binary frames (video)

```
Byte 0:    0x01 (video frame message type)
Byte 1:    displayIndex (0–7)
Bytes 2–5: timestamp in ms (UInt32, big-endian)
Byte 6:    flags (bit 0 = keyframe)
Bytes 7+:  H.264 Annex B data
```

---

## Getting Started

### Mac Companion App

**Requirements:** macOS 13.0+, Xcode 15+

```bash
cd AirDesk-Mac

# Generate Xcode project (requires XcodeGen)
brew install xcodegen
xcodegen generate

# Open in Xcode
open AirDesk-Mac.xcodeproj
```

On first launch:
1. Grant **Screen Recording** in System Settings → Privacy & Security
2. Grant **Accessibility** in System Settings → Privacy & Security
3. Click the menu bar icon → **Start Sharing**

### iOS App

**Requirements:** iOS 16.0+, Xcode 15+

```bash
cd AirDesk-iOS
xcodegen generate
open AirDesk.xcodeproj
```

Run on device or simulator. Both Mac and iOS must be on the same Wi-Fi network.

---

## Touch Controls

| Gesture | Action |
|---------|--------|
| Tap | Left click |
| Long press | Right click |
| Single finger drag | Mouse drag |
| Two-finger drag | Scroll |
| Pinch | Zoom local view |
| Swipe left/right | Switch monitor |

---

## Cloudflare Landing Page

```bash
cd Cloudflare/landing-page

# Deploy via Cloudflare Pages direct upload
# Requires: Cloudflare account with Pages enabled
wrangler pages deploy . --project-name airdesk-landing
```

Live at: https://airdesk-landing.pages.dev

---

## Roadmap

- [x] V1: Local network (LAN) remote desktop
- [ ] V2: Cloudflare Tunnel for remote access from anywhere
- [ ] V2: Clipboard sync (text + images)
- [ ] V2: Audio streaming
- [ ] V2: File transfer

---

## Project Structure

```
MacRemoteDesktop/
├── AirDesk-Mac/          macOS companion app
│   ├── Sources/AirDesk/
│   │   ├── MenuBar/      Status bar controller
│   │   ├── Capture/      ScreenCaptureKit + H264 encoder
│   │   ├── Server/       WebSocket server + protocol
│   │   ├── Input/        Mouse + keyboard injection
│   │   ├── Tunnel/       Cloudflare tunnel manager
│   │   └── Utils/        Bonjour + permissions
│   ├── Info.plist
│   ├── AirDesk.entitlements
│   └── project.yml       XcodeGen spec
├── AirDesk-iOS/          iOS client app
│   ├── AirDesk/
│   │   ├── App/          Entry point + AppState
│   │   ├── Models/       Data models + protocol types
│   │   ├── Services/     Discovery + WebSocket + VideoDecoder
│   │   ├── Views/        SwiftUI views + Metal renderer
│   │   └── Utils/        TouchInputMapper
│   └── project.yml       XcodeGen spec
├── Cloudflare/
│   └── landing-page/     Static site for Cloudflare Pages
├── QA/
│   ├── mac-app-test-plan.md
│   └── ios-app-test-plan.md
└── README.md
```

---

Built by [helloxtech](https://github.com/helloxtech)
