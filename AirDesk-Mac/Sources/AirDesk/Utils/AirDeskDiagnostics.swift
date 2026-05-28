import AppKit
import Foundation

final class AirDeskDiagnostics {
    static let shared = AirDeskDiagnostics()

    private let queue = DispatchQueue(label: "airdesk.mac.diagnostics")
    private var events: [String] = []
    private let maxEvents = 600
    private let cleanShutdownKey = "airdesk.diagnostics.cleanShutdown"
    private let persistedEventsKey = "airdesk.diagnostics.events.v1"
    private let installationIDKey = "airdesk.diagnostics.installationID.v1"
    private let issueReportURL = URL(string: "https://hellox.ca/api/app-issue-report")!

    private init() {
        events = UserDefaults.standard.stringArray(forKey: persistedEventsKey) ?? []
    }

    func installCrashMarker() {
        let wasClean = UserDefaults.standard.object(forKey: cleanShutdownKey) as? Bool ?? true
        if !wasClean {
            record("Previous app session ended unexpectedly")
            uploadIssueReport(
                action: "crash_recovery",
                reason: "previous_session_ended_unexpectedly",
                severity: "critical",
                errorMessage: "Previous AirDesk Mac session ended unexpectedly."
            )
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
            UserDefaults.standard.set(self.events, forKey: self.persistedEventsKey)
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
            "toolId": "mac",
            "toolLabel": "Mac App",
            "action": action,
            "severity": severity,
            "appVersion": Self.appVersion,
            "buildVersion": Self.buildVersion,
            "distribution": Self.distribution,
            "platform": "macos",
            "arch": Self.architecture,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
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

    private func contextSnapshot(reason: String, extraContext: [String: Any]) -> [String: Any] {
        var snapshot: [String] = []
        queue.sync { snapshot = events }
        var context: [String: Any] = [
            "reason": reason,
            "host": Host.current().localizedName ?? "Unknown",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": Self.appVersion,
            "buildVersion": Self.buildVersion,
            "distribution": Self.distribution,
            "installationId": Self.installationID(key: installationIDKey),
            "permissions": [
                "screenRecording": PermissionChecker.hasScreenRecordingPermission(),
                "accessibility": PermissionChecker.hasAccessibilityPermission()
            ],
            "recentEvents": snapshot
        ]
        extraContext.forEach { context[$0.key] = $0.value }
        return context
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    private static var distribution: String {
        #if APP_STORE
        return "mac-app-store"
        #else
        return "direct-download"
        #endif
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
