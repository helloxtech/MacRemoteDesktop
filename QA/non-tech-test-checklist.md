# AirDesk — Plain-Language Test Checklist (iOS 1.2.9 / Mac 1.2.11)

This checklist is written for a **non-technical tester**. No jargon. Just do each
step on your iPhone/iPad with your Mac, and check the box if it behaves as
described. If something is different, jot a note in the "Notes" column.

**What you need**
- Your Mac running the AirDesk Mac app, with **Start Sharing** on.
- Your Mac connected to **two or more screens** (for the screen-switch tests).
- Your iPhone/iPad on the **same Wi-Fi** as the Mac, with AirDesk **build 1.2.9 (20)** installed.

> How to confirm the build: this is the version we just fixed. If you still see
> 1.2.8, the new build isn't installed yet (see "Getting the new build on your
> device" at the bottom).

---

## A. The screen-switch buttons are back (the main complaint)

| # | Do this | What should happen | OK? | Notes |
|---|---------|--------------------|-----|-------|
| A1 | Connect to your Mac (tap it under "Nearby Macs", Local mode) | You see your Mac's desktop | ☐ | |
| A2 | Look at the **top-left** of the screen | You see a row like **‹ [Screen 1] [Screen 2] ›** | ☐ | |
| A3 | Tap **Screen 2** | The view switches to your second monitor | ☐ | |
| A4 | Tap **Screen 1** | It switches back to the first monitor | ☐ | |
| A5 | Tap the **›** (right arrow) a few times | It steps through your screens and wraps around to the first | ☐ | |
| A6 | Tap the small **chevron** to hide the toolbar | The bottom buttons hide, **but the Screen 1 / Screen 2 row stays visible** | ☐ | |
| A7 | (If your Mac has only one screen) connect | No screen switcher appears — correct, there's nothing to switch | ☐ | |

**This is the fix for "the icons disappeared."** The switcher now stays on screen
whenever your Mac has more than one display, even with the toolbar hidden.

| # | Do this | What should happen | OK? | Notes |
|---|---------|--------------------|-----|-------|
| A8 | Look at the very top while connected | Everything sits on **one row**: ✕ · screen switcher · fps · ⌄ (no second stacked bar) | ☐ | |

---

## A2. Scrolling stays live (fixed in iPhone build 20 and Mac build 29)

Previously the Mac would scroll but the **iPhone picture froze** until you lifted
your finger. It should now keep moving while you scroll.

| # | Do this | What should happen | OK? | Notes |
|---|---------|--------------------|-----|-------|
| S1 | Open a long web page/document on the Mac, switch to **Scroll** mode, drag to scroll | The picture on the iPhone **keeps updating while your finger is moving** — it does not freeze until release | ☐ | |
| S2 | In **Control** mode, scroll with **two fingers** | Same — the view updates live during the gesture | ☐ | |
| S3 | Scroll continuously a few seconds, then stop | Motion is smooth during the scroll; final position is correct when you stop | ☐ | If still laggy, note the **ms** in the badge and Local vs Remote |

---

## B. No more black screen / "have to quit and reopen"

| # | Do this | What should happen | OK? | Notes |
|---|---------|--------------------|-----|-------|
| B1 | While connected, press the **Home gesture / switch to another app** for ~30 seconds | — | ☐ | |
| B2 | Come **back to AirDesk** | The desktop comes back on its own within a few seconds (you may briefly see a "Loading Mac screen" card) | ☐ | |
| B3 | Connect again, then leave AirDesk in the background for **several minutes** | — | ☐ | |
| B4 | Come back to AirDesk | You see a brief **"Reconnecting…"** card, then your desktop returns — **without** force-quitting | ☐ | |
| B5 | While connected, turn iPhone **Wi-Fi off, then back on** | App shows "Reconnecting…", then the desktop returns by itself | ☐ | |
| B6 | Leave the Mac desktop **totally still** (don't touch it) for a minute while connected | Connection stays alive — it does **not** drop just because nothing moved | ☐ | |
| B7 | If a connection ever looks stuck, tap **"Reconnect now"** on the status card | It immediately tries again instead of making you wait | ☐ | |

**This is the fix for the reconnect black-out.** The app now notices a dead
connection on its own and rebuilds the picture, so quitting and reopening
shouldn't be necessary anymore.

---

## C. Everyday smoothness (general feel)

| # | Do this | What should happen | OK? | Notes |
|---|---------|--------------------|-----|-------|
| C1 | Tap somewhere on the Mac screen | The Mac clicks exactly where you tapped | ☐ | |
| C2 | Pinch to zoom in, drag to move around | View zooms and pans smoothly | ☐ | |
| C3 | Open the keyboard button and type | Text appears on the Mac | ☐ | |
| C4 | Switch the Control / Scroll buttons and try scrolling a web page | Scrolling works in Scroll mode | ☐ | |
| C5 | Tap the **X** (top-left) to leave | Returns to the Mac list cleanly | ☐ | |

---

## How to report a problem

For anything that fails, note: **which step (e.g. B4)**, what you saw instead,
and roughly how long it took. If the app shows an error, there's a **Report
Issue** button — tapping it sends diagnostics automatically.

---

## Getting the new build (1.2.9) on your device

These fixes are in the source code and the app compiles cleanly. To put the new
build on your iPhone/iPad:

1. On your Mac, open `AirDesk-iOS/AirDesk.xcodeproj` in Xcode.
2. Plug in your iPhone/iPad and select it as the run target.
3. Press **Run** (▶). Xcode installs build **1.2.9 (20)** on the device.

The Mac companion was also updated to **1.2.11 (29)** so very large displays stream at a lower, steadier resolution.
