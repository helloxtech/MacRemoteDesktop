import Foundation
import UIKit
import SwiftUI
import AirDeskProtocol

final class AirDeskDiagnostics {
    static let shared = AirDeskDiagnostics()

    private let queue = DispatchQueue(label: "airdesk.ios.diagnostics")
    private var events: [String] = []
    private let maxEvents = 400
    private let cleanShutdownKey = "airdesk.diagnostics.cleanShutdown"
    private let persistedEventsKey = "airdesk.diagnostics.events.v1"
    private let installationIDKey = "airdesk.diagnostics.installationID.v1"
    private let automaticIssueReportLastSentKeyPrefix = "airdesk.diagnostics.automaticIssueReport.lastSent"
    private let issueReportURL = URL(string: "https://hellox.ca/api/app-issue-report")!

    private init() {
        events = UserDefaults.standard.stringArray(forKey: persistedEventsKey) ?? []
    }

    func installLifecycleObservers() {
        let wasClean = UserDefaults.standard.object(forKey: cleanShutdownKey) as? Bool ?? true
        if !wasClean {
            record("Previous app session ended unexpectedly")
            uploadIssueReport(
                action: "crash_recovery",
                reason: "previous_session_ended_unexpectedly",
                severity: "critical",
                errorMessage: "Previous AirDesk iOS session ended unexpectedly."
            )
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
            UserDefaults.standard.set(self.events, forKey: self.persistedEventsKey)
        }
    }

    func uploadIssueReport(
        action: String,
        reason: String,
        severity: String = "error",
        errorMessage: String,
        context: [String: Any] = [:],
        completion: ((Result<String, Error>) -> Void)? = nil
    ) {
        let reportID = UUID().uuidString
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "product": "airdesk",
            "reportId": reportID,
            "toolId": "ios",
            "toolLabel": "iOS App",
            "action": action,
            "severity": severity,
            "appVersion": Self.appVersion,
            "buildVersion": Self.buildVersion,
            "distribution": Self.distribution,
            "platform": "ios",
            "arch": Self.architecture,
            "osVersion": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "occurredAt": Self.timestamp(),
            "error": [
                "name": "AirDeskIssue",
                "code": reason,
                "message": errorMessage
            ],
            "context": contextSnapshot(reason: reason, extraContext: context)
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            completion?(.failure(IssueReportError.invalidPayload))
            return
        }

        var request = URLRequest(url: issueReportURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                self.record("Issue report upload failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion?(.failure(error)) }
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                let message = Self.serverErrorMessage(from: data) ?? "Issue report server returned \(httpResponse.statusCode)."
                self.record("Issue report upload rejected: \(message)")
                DispatchQueue.main.async { completion?(.failure(IssueReportError.serverRejected(message))) }
                return
            }

            let serverReportID = Self.reportID(from: data) ?? reportID
            self.record("Issue report uploaded: \(serverReportID)")
            DispatchQueue.main.async { completion?(.success(serverReportID)) }
        }.resume()
    }

    func uploadAutomaticIssueReport(
        action: String,
        reason: String,
        severity: String = "error",
        errorMessage: String,
        context: [String: Any] = [:],
        throttleInterval: TimeInterval = 10 * 60
    ) {
        let now = Date()
        let throttle = AutomaticIssueReportThrottle(interval: throttleInterval)
        let lastSentKey = automaticIssueReportLastSentKey(for: reason)
        let lastSentAt = UserDefaults.standard.object(forKey: lastSentKey) as? Date

        guard throttle.shouldSend(lastSentAt: lastSentAt, now: now) else {
            record("Automatic issue report throttled: \(reason)")
            return
        }

        UserDefaults.standard.set(now, forKey: lastSentKey)
        record("Automatic issue report requested: \(reason)")
        uploadIssueReport(
            action: action,
            reason: reason,
            severity: severity,
            errorMessage: errorMessage,
            context: context
        )
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

    private func contextSnapshot(reason: String, extraContext: [String: Any]) -> [String: Any] {
        var snapshot: [String] = []
        queue.sync { snapshot = events }
        var context: [String: Any] = [
            "reason": reason,
            "deviceName": UIDevice.current.name,
            "deviceModel": UIDevice.current.model,
            "systemName": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "appVersion": Self.appVersion,
            "buildVersion": Self.buildVersion,
            "distribution": Self.distribution,
            "installationId": Self.installationID(key: installationIDKey),
            "recentEvents": snapshot
        ]
        extraContext.forEach { context[$0.key] = $0.value }
        return context
    }

    private func automaticIssueReportLastSentKey(for reason: String) -> String {
        let safeReason = reason.replacingOccurrences(
            of: "[^A-Za-z0-9_.-]",
            with: "_",
            options: .regularExpression
        )
        return "\(automaticIssueReportLastSentKeyPrefix).\(safeReason)"
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    private static var distribution: String {
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return "testflight-or-sandbox"
        }
        return "app-store"
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func installationID(key: String) -> String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static func reportID(from data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reportID = json["reportId"] as? String,
              !reportID.isEmpty else {
            return nil
        }
        return reportID
    }

    private static func serverErrorMessage(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String,
           !error.isEmpty {
            return error
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240).description
    }

    private enum IssueReportError: LocalizedError {
        case invalidPayload
        case serverRejected(String)

        var errorDescription: String? {
            switch self {
            case .invalidPayload:
                return "Issue report could not be prepared."
            case .serverRejected(let message):
                return message
            }
        }
    }
}

struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
