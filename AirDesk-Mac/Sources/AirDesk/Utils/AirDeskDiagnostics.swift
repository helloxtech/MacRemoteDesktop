import AppKit
import Foundation

final class AirDeskDiagnostics {
    static let shared = AirDeskDiagnostics()

    private let queue = DispatchQueue(label: "airdesk.mac.diagnostics")
    private var events: [String] = []
    private let maxEvents = 600
    private let cleanShutdownKey = "airdesk.diagnostics.cleanShutdown"

    private init() {}

    func installCrashMarker() {
        let wasClean = UserDefaults.standard.object(forKey: cleanShutdownKey) as? Bool ?? true
        if !wasClean {
            record("Previous app session ended unexpectedly")
        }
        UserDefaults.standard.set(false, forKey: cleanShutdownKey)
    }

    func markCleanShutdown() {
        record("Application will terminate")
        UserDefaults.standard.set(true, forKey: cleanShutdownKey)
    }

    func record(_ message: String) {
        let line = "\(Self.timestamp()) macOS \(message)"
        NSLog("[AirDesk] %@", message)
        queue.async { [weak self] in
            guard let self else { return }
            self.events.append(line)
            if self.events.count > self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents)
            }
        }
    }

    func exportText() -> String {
        var snapshot: [String] = []
        queue.sync { snapshot = events }
        return """
        AirDesk Mac Diagnostics
        Generated: \(Self.timestamp())
        Host: \(Host.current().localizedName ?? "Unknown")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))

        Permissions:
        Screen Recording: \(PermissionChecker.hasScreenRecordingPermission() ? "granted" : "missing")
        Accessibility: \(PermissionChecker.hasAccessibilityPermission() ? "granted" : "missing")

        Events:
        \(snapshot.joined(separator: "\n"))
        """
    }

    func writeExport(to url: URL) throws {
        try exportText().write(to: url, atomically: true, encoding: .utf8)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
