import CoreGraphics
import AppKit

class InputInjector: NSObject {

    func handleMouseMessage(_ msg: MouseMessage) {
        guard let display = displayForIndex(msg.displayIndex) else { return }

        let screenBounds = CGDisplayBounds(display)
        let x = screenBounds.origin.x + CGFloat(msg.x) * screenBounds.width
        let y = screenBounds.origin.y + CGFloat(msg.y) * screenBounds.height
        let point = CGPoint(x: x, y: y)

        switch msg.action {
        case "move":
            postMouseEvent(type: .mouseMoved, point: point, button: .left)

        case "click":
            postMouseEvent(type: .leftMouseDown, point: point, button: .left)
            postMouseEvent(type: .leftMouseUp, point: point, button: .left)

        case "rightClick":
            postMouseEvent(type: .rightMouseDown, point: point, button: .right)
            postMouseEvent(type: .rightMouseUp, point: point, button: .right)

        case "drag":
            postMouseEvent(type: .leftMouseDown, point: point, button: .left)
            postMouseEvent(type: .leftMouseDragged, point: point, button: .left)

        case "dragEnd":
            postMouseEvent(type: .leftMouseUp, point: point, button: .left)

        case "scroll":
            let dx = Int32(msg.scrollDeltaX ?? 0)
            let dy = Int32(msg.scrollDeltaY ?? 0)
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                event.post(tap: .cghidEventTap)
            }

        default:
            break
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

    private func postMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func displayForIndex(_ index: Int) -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        guard index < displays.count else { return nil }
        return displays[index]
    }
}
