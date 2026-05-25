import AppKit
import AirDeskProtocol

enum PermissionChecker {
    private static var requestedScreenRecordingThisLaunch = false
    private static var requestedAccessibilityThisLaunch = false

    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func currentStatusMessage() -> PermissionStatusMessage {
        let screenRecording = hasScreenRecordingPermission()
        let accessibility = hasAccessibilityPermission()

        let message: String
        if !screenRecording {
            message = "Screen sharing is blocked. Enable Screen Recording for AirDesk in macOS Settings."
        } else if !accessibility {
            message = "Viewing only: enable Accessibility for AirDesk to allow clicks and typing."
        } else {
            message = "Control ready"
        }

        return PermissionStatusMessage(
            screenRecording: screenRecording,
            accessibility: accessibility,
            canView: screenRecording,
            canControl: screenRecording && accessibility,
            message: message
        )
    }

    static func openScreenRecordingSettings() {
        openPrivacySettings("Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        openPrivacySettings("Privacy_Accessibility")
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
            openScreenRecordingSettings()
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
            openAccessibilitySettings()
        }
    }

    private static func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
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
