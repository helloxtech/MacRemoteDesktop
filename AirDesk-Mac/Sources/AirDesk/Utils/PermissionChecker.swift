import AppKit

enum PermissionChecker {
    private static var requestedScreenRecordingThisLaunch = false
    private static var requestedAccessibilityThisLaunch = false

    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func ensureScreenRecordingPermissionForSharing() -> Bool {
        if hasScreenRecordingPermission() {
            return true
        }

        if !requestedScreenRecordingThisLaunch {
            requestedScreenRecordingThisLaunch = true
            _ = CGRequestScreenCaptureAccess()
            return hasScreenRecordingPermission()
        }

        showAlert(
            title: "Screen Recording Required",
            message: "AirDesk still can't capture your display.\n\nIf you just enabled Screen Recording in System Settings, quit and reopen AirDesk, then click Start Sharing again.",
            action: "Open System Settings"
        ) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }

    static func requestAccessibilityPermissionIfNeeded() {
        guard !hasAccessibilityPermission() else { return }

        if !requestedAccessibilityThisLaunch {
            requestedAccessibilityThisLaunch = true
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }

        showAlert(
            title: "Accessibility Recommended",
            message: "AirDesk can share your screen without Accessibility, but remote mouse and keyboard control need it.\n\nIf you just enabled Accessibility in System Settings, quit and reopen AirDesk to apply the change.",
            action: "Open System Settings"
        ) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
