import CoreGraphics
import AppKit

class InputInjector: NSObject {

    private var accessibilityWarned = false

    func handleMouseMessage(_ msg: MouseMessage) {
        if !accessibilityWarned && !AXIsProcessTrusted() {
            NSLog("[AirDesk] WARNING: Accessibility not granted — mouse/keyboard events will be silently dropped!")
            accessibilityWarned = true
        }
        NSLog("[AirDesk] Mouse: \(msg.action) at (\(msg.x), \(msg.y)) display=\(msg.displayIndex)")
        guard let display = displayForIndex(msg.displayIndex) else {
            NSLog("[AirDesk] ERROR: No display found for index \(msg.displayIndex)")
            return
        }

        let screenBounds = CGDisplayBounds(display)
        let x = screenBounds.origin.x + CGFloat(msg.x) * screenBounds.width
        let y = screenBounds.origin.y + CGFloat(msg.y) * screenBounds.height
        let point = CGPoint(x: x, y: y)

        switch msg.action {
        case "move":
            warpCursor(to: point)
            postMouseEvent(type: .mouseMoved, point: point, button: .left)

        case "click":
            warpCursor(to: point)
            postMouseEvent(type: .leftMouseDown, point: point, button: .left)
            // Small delay so the target app registers the mouseDown before mouseUp.
            // Some macOS controls (small buttons, tab bar "+") drop instant down-up pairs.
            usleep(30_000)  // 30ms
            postMouseEvent(type: .leftMouseUp, point: point, button: .left)

        case "doubleClick":
            warpCursor(to: point)
            postMouseEvent(type: .leftMouseDown, point: point, button: .left, clickCount: 1)
            postMouseEvent(type: .leftMouseUp, point: point, button: .left, clickCount: 1)
            postMouseEvent(type: .leftMouseDown, point: point, button: .left, clickCount: 2)
            postMouseEvent(type: .leftMouseUp, point: point, button: .left, clickCount: 2)

        case "rightClick":
            warpCursor(to: point)
            postMouseEvent(type: .rightMouseDown, point: point, button: .right)
            postMouseEvent(type: .rightMouseUp, point: point, button: .right)

        case "drag":
            warpCursor(to: point)
            postMouseEvent(type: .leftMouseDown, point: point, button: .left)

        case "mouseDrag":
            // Intermediate drag position — must use leftMouseDragged (not mouseMoved)
            // so macOS window dragging and selection work correctly
            postMouseEvent(type: .leftMouseDragged, point: point, button: .left)

        case "dragEnd":
            postMouseEvent(type: .leftMouseUp, point: point, button: .left)

        case "scroll":
            // Warp cursor to scroll position so macOS delivers the event
            // to the correct window — no separate tap needed on iOS side.
            warpCursor(to: point)
            let dx = Int32(msg.scrollDeltaX ?? 0)
            let dy = Int32(msg.scrollDeltaY ?? 0)
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                event.post(tap: .cghidEventTap)
            }

        default:
            break
        }
    }

    func handleSystemAction(_ msg: SystemActionMessage) {
        NSLog("[AirDesk] System action received: \(msg.action)")
        switch msg.action {
        case "mission_control":
            // Use /usr/bin/open which reliably launches system apps
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Mission Control"]
            do {
                try process.run()
                NSLog("[AirDesk] Mission Control launched")
            } catch {
                NSLog("[AirDesk] Failed to launch Mission Control: \(error)")
            }
        default:
            NSLog("[AirDesk] Unknown system action: \(msg.action)")
        }
    }

    func handleKeyboardMessage(_ msg: KeyboardMessage) {
        let keyDown = msg.action == "down"
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(msg.keyCode), keyDown: keyDown) else { return }

        var flags = CGEventFlags()
        for modifier in msg.modifiers {
            switch modifier {
            case "cmd":   flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt":   flags.insert(.maskAlternate)
            case "ctrl":  flags.insert(.maskControl)
            default: break
            }
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Synchronously moves the cursor to `point`. Unlike mouseMoved CGEvent
    /// (which is asynchronous), CGWarpMouseCursorPosition is guaranteed to
    /// complete before returning, so subsequent mouseDown events target the
    /// correct position.
    private func warpCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Re-associate so the next real mouse movement isn't treated as a huge delta
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func postMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton, clickCount: Int64 = 1) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.post(tap: .cghidEventTap)
    }

    // Cache avoids calling CGGetActiveDisplayList on every mouse event
    private var cachedDisplays: [CGDirectDisplayID] = []
    private var lastDisplayFetch: Date = .distantPast

    private func displayForIndex(_ index: Int) -> CGDirectDisplayID? {
        if Date().timeIntervalSince(lastDisplayFetch) > 2.0 {
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &displays, &count)
            // Sort by ID to match the deterministic order used by ScreenCaptureManager.
            cachedDisplays = displays.sorted()
            lastDisplayFetch = Date()
        }
        guard index < cachedDisplays.count else { return nil }
        return cachedDisplays[index]
    }
}
