import Foundation
import UIKit
import SwiftUI

final class AirDeskDiagnostics {
    static let shared = AirDeskDiagnostics()

    private let queue = DispatchQueue(label: "airdesk.ios.diagnostics")
    private var events: [String] = []
    private let maxEvents = 400
    private let cleanShutdownKey = "airdesk.diagnostics.cleanShutdown"

    private init() {}

    func installLifecycleObservers() {
        let wasClean = UserDefaults.standard.object(forKey: cleanShutdownKey) as? Bool ?? true
        if !wasClean {
            record("Previous app session ended unexpectedly")
        }
        UserDefaults.standard.set(false, forKey: cleanShutdownKey)

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.record("App entered background")
            UserDefaults.standard.set(true, forKey: self.cleanShutdownKey)
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(false, forKey: self.cleanShutdownKey)
            self.record("App entered foreground")
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.record("App will terminate")
            UserDefaults.standard.set(true, forKey: self.cleanShutdownKey)
        }
    }

    func record(_ message: String) {
        let line = "\(Self.timestamp()) iOS \(message)"
        NSLog("[AirDesk] %@", message)
        queue.async { [weak self] in
            guard let self else { return }
            self.events.append(line)
            if self.events.count > self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents)
            }
        }
    }

    func exportFile() -> URL {
        let text = exportText()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirDesk-iOS-Diagnostics-\(Self.fileTimestamp()).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func exportText() -> String {
        var snapshot: [String] = []
        queue.sync { snapshot = events }
        return """
        AirDesk iOS Diagnostics
        Generated: \(Self.timestamp())
        Device: \(UIDevice.current.name) \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))

        Events:
        \(snapshot.joined(separator: "\n"))
        """
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
