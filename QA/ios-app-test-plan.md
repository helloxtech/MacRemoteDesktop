# QA Test Plan — AirDesk iOS App
**QA Engineer #2 | Version 1.2.0**

---

## 1. Connection Screen

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| C-01 | App launches | Open AirDesk | Connection screen shown, Bonjour discovery starts |
| C-02 | Mac auto-discovery | Mac running AirDesk on same Wi-Fi | Mac appears in "Nearby Macs" list |
| C-03 | Multiple Macs | 2 Macs running AirDesk | Both appear in list |
| C-04 | Mac disappears | Quit AirDesk on Mac | Entry removed from list |
| C-05 | Manual IP connect | Enter valid IP + port, tap Connect | Connection attempt initiated |
| C-06 | Invalid IP | Enter invalid IP, tap Connect | Error message shown |
| C-07 | Wrong port | Enter correct IP, wrong port | Connection fails gracefully, error shown |
| C-08 | Discovery loading state | Before any Mac found | Spinner shown with "Scanning local network..." |
| C-09 | Remote mode notice | Select Remote mode | Remote mode explains that a successful scan is saved for next time |
| C-10 | Remote URL normalization | Enter a https trycloudflare.com URL | App connects with secure WebSocket tunnel URL |
| C-11 | Invalid remote URL | Enter invalid Remote URL, tap Connect Remotely | Error message shown |
| C-12 | Connection modes | Open the connection mode picker | Modes are labeled Local, Remote, and VNC |
| C-13 | Local mode copy | Select Local mode | Helper text explains same-Wi-Fi AirDesk streaming and pairing |
| C-14 | Remote QR scanner | Select Remote mode, tap Scan QR Code | Camera scanner opens and can be cancelled |
| C-15 | Saved Remote Access row | Connect successfully through a Remote QR code, disconnect, then return to Remote mode | Saved Remote Access shows the Mac and can be tapped to reconnect without scanning |

---

## 2. Connection Flow

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| CF-01 | Connecting state | Tap Mac in list | "Connecting to [name]..." spinner shown |
| CF-02 | Cancel while connecting | Tap Cancel | Returns to connection screen |
| CF-03 | Successful connection | Valid Mac running AirDesk | Transitions to remote desktop view |
| CF-04 | Connection refused | Mac AirDesk not sharing | Error shown, returns to connection screen |
| CF-05 | Reconnect on drop | Wi-Fi blip | Auto-reconnects with backoff |
| CF-06 | Max reconnect attempts | Sustained disconnection | Stops retrying, shows error |
| CF-07 | Remote tunnel connection | Paste active Mac tunnel URL and pairing code | Transitions to remote desktop view |
| CF-07A | Remote QR connection | Scan the QR code shown by the Mac AirDesk menu | Tunnel URL and pairing code are applied and the app connects automatically, retrying until monitor info arrives |
| CF-07B | Remote saved connection | Tap a Saved Remote Access row while the Mac Remote Access tunnel is still active | App reconnects using the saved URL and saved pairing/trust details without opening the QR scanner |
| CF-08 | First-time Local pairing prompt | Tap a Local Mac, or tap Connect Locally, on an iPhone that has no saved AirDesk trust token | Pairing Required sheet opens and asks for the six-digit Mac menu code before connecting |
| CF-09 | Local pairing retry | Enter the correct six-digit code in the pairing sheet | App retries automatically and transitions to remote desktop view |
| CF-10 | Incomplete pairing code | Enter fewer than six digits in the pairing sheet | Connect action remains disabled |

---

## 3. Remote Desktop View

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| RD-01 | Screen displayed | Connect successfully | Mac screen renders correctly |
| RD-02 | Correct aspect ratio | Check display bounds | No squishing/stretching, letterbox/pillarbox correct |
| RD-03 | Disconnect button | Tap Disconnect | Returns to connection screen |
| RD-04 | Full screen | Check layout | Status bar hidden, immersive view |
| RD-05 | Orientation change | Rotate device | View adapts, no crash |

---

## 4. Direct Touch Control (Core Feature)

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| T-01 | Tap = click | Tap on Mac screen | Click lands exactly where finger touched |
| T-02 | Tap accuracy | Tap a small button on Mac | Click lands on button (within ~5px) |
| T-03 | Long press = right click | Long press on desktop | Context menu appears on Mac |
| T-04 | Long press haptic | Long press | Haptic feedback on device |
| T-05 | Single finger drag | Drag an item | Item drags on Mac |
| T-06 | Two finger scroll up/down | Two-finger drag vertically | Page scrolls in correct direction |
| T-07 | Two finger scroll left/right | Two-finger drag horizontally | Horizontal scroll works |
| T-08 | Pinch zoom in | Pinch to zoom | Local view zooms (not sent to Mac) |
| T-09 | Pinch zoom out | Pinch to minimum | View snaps back to 1x |
| T-10 | Tap near edge | Tap at corner of display | Correct normalized coords sent |
| T-11 | Letterbox offset | Display in portrait with 16:9 Mac | Touch accounts for black bars |

---

## 5. Multi-Monitor

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| MM-01 | Multiple monitors shown | Mac has 2 displays | Two page dots shown at bottom |
| MM-02 | Swipe to switch monitor | Swipe left on remote view | Shows display 2 |
| MM-03 | Swipe back | Swipe right | Returns to display 1 |
| MM-04 | Tap page dot | Tap right page dot | Switches to display 2 |
| MM-05 | Active dot highlights | Switch monitors | Correct dot highlighted |
| MM-06 | Monitor name shown | 2+ monitors connected | Current monitor name in toolbar |
| MM-07 | Touch on correct display | Touch on display 2 view | Event sent with displayIndex=1 |
| MM-08 | Single monitor | Mac has 1 display | No page dots shown |

---

## 6. Video Decoding

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| VD-01 | First frame displayed | Connect and wait | Video appears within 2 seconds |
| VD-02 | Smooth playback | Watch for 30 seconds | No stuttering at 30fps |
| VD-03 | Keyframe recovery | Simulate packet loss | Video recovers on next keyframe |
| VD-04 | Resolution change | Resize Mac window | Video adjusts to new resolution |
| VD-05 | CPU usage | Profile during streaming | Below 20% CPU on modern device |
| VD-06 | Metal rendering | Check renderer | MetalVideoRenderer used, not CPU fallback |

---

## 7. iPad-Specific

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| iPad-01 | All orientations | Test all 4 orientations | App works in all orientations |
| iPad-02 | Layout in landscape | Connect in landscape | Full-screen immersive view |
| iPad-03 | Split View | Try split view | Graceful handling |
| iPad-04 | Touch precision | Tap small UI elements on Mac | Accurate click placement |

---

## 8. Integration Tests

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| INT-01 | Full connect → use → disconnect cycle | Full workflow | No memory leaks, clean state |
| INT-02 | Reconnect after force-quit Mac app | Kill Mac app, relaunch, reconnect | Works correctly |
| INT-03 | Background → foreground | Background iOS app, return | Reconnects or shows disconnected state |
| INT-04 | Long session (30+ min) | Leave connected 30 min | No crash, no memory growth |
| INT-05 | Rapid tap stress test | Tap rapidly for 10 seconds | No crash, events processed |
