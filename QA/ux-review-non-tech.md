# AirDesk — Non-Technical User UX Review

Goal: make AirDesk feel obvious to someone who is **not** a developer or IT person.
This document records (1) what changed in build 1.2.9 and (2) a prioritized
backlog of further improvements, so we can roll them out in safe, testable steps
rather than one risky rewrite.

---

## 1. Shipped in 1.2.9

- **Screen switcher always visible.** The "Screen 1 / Screen 2 …" control moved
  out of the collapsible toolbar into its own bar at the top left, with ‹ ›
  step arrows. It now appears whenever the Mac has 2+ displays and stays put
  when the toolbar is hidden. (Fixes "the icons disappeared.")
- **Automatic reconnect recovery.** The app detects a dead/half-open connection
  using the Mac's status heartbeat, rebuilds the video decoder, and reloads the
  picture when you return to the app — no more quit-and-reopen.
- **"Reconnect now" button** on the Connecting/Reconnecting cards as a manual
  escape hatch; the reconnect card's secondary action now reads **Disconnect**.
- **Apple-native offer-code entry.** The Remote Access paywall now uses Apple's
  StoreKit offer-code sheet and explains that purchases are handled securely by
  Apple; there is no custom HelloX unlock-code path for App Store builds.

---

## 2. Recommended next (prioritized)

### P1 — High impact, low risk

1. **Plain-English connection modes.** "Local / Remote / VNC" is jargon.
   Proposal: keep the tab labels but add a one-line subtitle under each, e.g.
   - Local → "Same Wi-Fi as your Mac (fastest)"
   - Remote → "Away from home — connect over the internet"
   - VNC → "Advanced: connect to Mac Screen Sharing"
   The helper text exists; surface it more prominently and consider renaming
   "VNC" to "Advanced (VNC)".

2. **First-run guidance / empty state.** When no Mac is found after ~8s, the
   "Scanning local network…" spinner should turn into a friendly tip: "No Mac
   found yet. On your Mac, open AirDesk and choose Start Sharing. Make sure both
   devices are on the same Wi-Fi." (Currently it spins indefinitely.)

3. **Label the remote toolbar buttons.** The bottom toolbar is a row of icons
   (arrows, ⌘ ⌃ ⌥ ⇧, mission control, clipboard). Add small text captions or at
   minimum VoiceOver accessibility labels on every button so the meaning isn't a
   guessing game. (Screen-switcher buttons already got accessibility labels.)

4. **A one-time coach overlay** the first time the remote desktop opens: 3 short
   tips ("Tap to click · Pinch to zoom · Switch screens up top"). Dismissible,
   shown once.

### P2 — Medium

5. **Friendlier modifier keys.** ⌘ ⌃ ⌥ ⇧ mean nothing to most users. Offer a
   small set of named shortcuts instead/alongside: "Copy", "Paste", "Undo",
   "Switch App", "Close Window".

6. **Connection quality wording.** The latency badge shows "45ms 30fps". For
   non-tech users, a colored dot + word ("Good / Fair / Slow") is clearer than
   milliseconds; keep the numbers for power users behind a tap.

7. **Clearer pairing copy.** The pairing sheet is good; add a tiny illustration
   or the exact menu path ("AirDesk menu-bar icon → the 6-digit code").

### P3 — Larger / later

8. **Onboarding wizard** for first launch: "Step 1: install the Mac app · Step
   2: Start Sharing · Step 3: pick your Mac". Replaces dropping a new user
   straight into a form.

9. **Audio + file transfer** (already on the roadmap) — non-tech users often
   expect sound and drag-to-transfer.

---

## 3. Notes on testing constraints

These changes are in a native iOS/macOS app, so live behavior (decoder,
background/foreground, multi-display) must be verified on real devices — see
`non-tech-test-checklist.md`. Automated unit tests cover the connection-state
logic (`WebSocketConnectionProgressTests`, etc.); the runtime video/reconnect
paths are device-only.
