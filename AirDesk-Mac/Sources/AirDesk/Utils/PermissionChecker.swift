import AppKit

enum PermissionChecker {

    static func requestPermissionsIfNeeded() {
        checkScreenRecording()
        checkAccessibility()
    }

    private static func checkScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            showAlert(
                title: "Screen Recording Required",
                message: "AirDesk needs Screen Recording permission to share your display.\n\nPlease grant access in System Settings → Privacy & Security → Screen Recording, then restart AirDesk.",
                action: "Open System Settings"
            ) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
    }

    private static func checkAccessibility() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            showAlert(
                title: "Accessibility Required",
                message: "AirDesk needs Accessibility permission to control your Mac remotely.\n\nPlease grant access in System Settings → Privacy & Security → Accessibility, then restart AirDesk.",
                action: "Open System Settings"
            ) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }

    private static func showAlert(title: String, message: String, action: String, handler: @escaping () -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: action)
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                handler()
            }
        }
    }
}
