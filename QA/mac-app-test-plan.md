# QA Test Plan — AirDesk Mac Companion App
**QA Engineer #1 | Version 1.0**

---

## 1. Permissions

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| P-01 | Screen Recording permission prompt | Launch app without Screen Recording permission | Alert shown, "Open System Settings" opens correct pane |
| P-02 | Accessibility permission prompt | Launch app without Accessibility permission | Alert shown, "Open System Settings" opens Accessibility pane |
| P-03 | Both permissions granted | Grant both permissions, relaunch | App starts silently, no permission alerts |
| P-04 | Permission revoked mid-session | Revoke Screen Recording while sharing | Capture stops gracefully, error logged |

---

## 2. Menu Bar

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| M-01 | App launches in menu bar | Launch AirDesk | Icon appears in menu bar, no Dock icon |
| M-02 | Menu opens | Click menu bar icon | Menu shows correct items |
| M-03 | Start Sharing | Click "Start Sharing" | Label changes to "Stop Sharing", WebSocket server starts |
| M-04 | Stop Sharing | Click "Stop Sharing" | Server stops, captures stop |
| M-05 | Client count updates | Connect iOS client | "1 client connected" shown in menu |
| M-06 | Multiple clients | Connect 2 iOS clients | "2 clients connected" shown |
| M-07 | Client disconnect | Disconnect iOS client | Count decrements correctly |
| M-08 | Quit | Click "Quit AirDesk" | App terminates, server stops |

---

## 3. Screen Capture

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| SC-01 | Single display capture | Start sharing, 1 monitor | ScreenCaptureKit captures at 30fps |
| SC-02 | Multi-display capture | Start sharing, 2+ monitors | Each display captured independently |
| SC-03 | Display resolution | Compare captured resolution | Matches actual display resolution |
| SC-04 | Dynamic display add | Plug in second monitor while sharing | New stream starts automatically |
| SC-05 | Dynamic display remove | Unplug monitor while sharing | Stream stops without crash |

---

## 4. H.264 Encoding

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| E-01 | Keyframe generation | Monitor encoded output | Keyframe every ~2 seconds (60 frames at 30fps) |
| E-02 | Annex B format | Inspect encoded data | Starts with 0x00 0x00 0x00 0x01 start codes |
| E-03 | SPS/PPS in keyframe | First encoded frame | SPS and PPS NAL units present |
| E-04 | Bitrate | Profile CPU/bandwidth | ~2Mbps average, spikes on keyframes |

---

## 5. WebSocket Server

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| WS-01 | Server starts on port 7890 | Start sharing | TCP listener on port 7890 |
| WS-02 | WebSocket handshake | Connect client | HTTP Upgrade accepted |
| WS-03 | screen_info sent on connect | Connect client, send connect message | JSON with monitor array received |
| WS-04 | Video frames streamed | Connect and request stream | Binary frames arriving at ~30fps |
| WS-05 | Binary frame header | Inspect first byte | Byte 0 = 0x01, correct display index |
| WS-06 | Multiple clients | Connect 2 clients simultaneously | Both receive video streams |
| WS-07 | Client disconnect | Force-close client | Server removes connection, no crash |

---

## 6. Input Injection

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| I-01 | Mouse move | Send mouse move message | Mac cursor moves to correct position |
| I-02 | Left click | Send click action | Click registered at correct coordinates |
| I-03 | Right click | Send rightClick action | Context menu appears at position |
| I-04 | Scroll | Send scroll action with deltas | Page scrolls correctly |
| I-05 | Drag | Send drag + move + dragEnd sequence | Window or object dragged |
| I-06 | Keyboard key | Send key down/up | Key press registered |
| I-07 | Modifier keys | Send Cmd+C | Copy action executed |
| I-08 | Multi-monitor coords | Click on display 1 with index 1 | Click lands on correct display |

---

## 7. Bonjour Advertisement

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| B-01 | Service advertised | Start app | "_airdesk._tcp." visible via dns-sd on local network |
| B-02 | TXT record | Inspect service | version=1.0, name=hostname present |
| B-03 | Service removed on quit | Quit app | Service no longer visible via dns-sd |

---

## 8. Cloudflare Tunnel

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| CF-01 | cloudflared not installed | Start tunnel without cloudflared | Informative error logged, no crash |
| CF-02 | cloudflared installed | Install cloudflared, trigger tunnel | Process spawns, URL extracted from stdout |
| CF-03 | Tunnel URL parsed | Start tunnel | trycloudflare.com URL shown in menu |
| CF-04 | Tunnel stop | Stop sharing | cloudflared process terminated |
