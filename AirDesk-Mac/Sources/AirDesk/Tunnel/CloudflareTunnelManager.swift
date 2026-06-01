import Foundation

protocol TunnelDiagnosticsReporting {
    func record(_ message: String)
    func uploadAutomaticIssueReport(
        action: String,
        reason: String,
        errorMessage: String,
        context: [String: Any]
    )
}

struct NoopTunnelDiagnosticsReporter: TunnelDiagnosticsReporting {
    func record(_ message: String) {}

    func uploadAutomaticIssueReport(
        action: String,
        reason: String,
        errorMessage: String,
        context: [String: Any]
    ) {}
}

class CloudflareTunnelManager {

    private var process: Process?
    private let readinessQueue = DispatchQueue(label: "airdesk.cloudflare.readiness")
    private let outputQueue = DispatchQueue(label: "airdesk.cloudflare.output")
    private let diagnostics: TunnelDiagnosticsReporting
    private var readinessGate = TunnelURLReadinessGate()
    private var readinessProbe: TunnelWebSocketReadinessProbe?
    private var isStopping = false
    private var isRestartingAfterUnreadyURL = false
    private var activeLocalPort: UInt16 = 7890
    private var recentOutputLines: [String] = []
    var urlHandler: ((String?) -> Void)?
    var isRunning: Bool {
        process?.isRunning == true
    }

    init(diagnostics: TunnelDiagnosticsReporting = NoopTunnelDiagnosticsReporter()) {
        self.diagnostics = diagnostics
    }

    private var cloudflaredURLs: [URL] {
        var urls: [URL] = []
        if let helperURL = Bundle.main.url(forAuxiliaryExecutable: "cloudflared") {
            urls.append(helperURL)
        }
        if let resourceURL = Bundle.main.url(forResource: "cloudflared", withExtension: nil) {
            urls.append(resourceURL)
        }
        urls.append(URL(fileURLWithPath: "/usr/local/bin/cloudflared"))
        urls.append(URL(fileURLWithPath: "/opt/homebrew/bin/cloudflared"))
        return urls
    }

    @discardableResult
    func start(localPort: UInt16 = 7890) -> Bool {
        guard !isRunning else { return true }
        activeLocalPort = localPort
        isStopping = false
        resetRecentOutput()
        guard let binaryURL = cloudflaredURLs.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            let message = "Cloudflare tunnel helper was not found or was not executable."
            print("CloudflareTunnelManager: \(message)")
            diagnostics.record("Cloudflare tunnel helper missing")
            diagnostics.uploadAutomaticIssueReport(
                action: "remote_access_start_failed",
                reason: "tunnel_helper_missing",
                errorMessage: message,
                context: tunnelDiagnosticsContext(localPort: localPort)
            )
            urlHandler?(nil)
            return false
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["tunnel", "--url", "http://localhost:\(localPort)", "--no-autoupdate"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.appendTunnelOutput(output)
            if let url = self?.extractURL(from: output) {
                self?.publishURLWhenReady(url)
            }
        }

        proc.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            let wasStopping = self.isStopping
            let shouldRestart = self.isRestartingAfterUnreadyURL && !wasStopping
            self.isStopping = false
            self.isRestartingAfterUnreadyURL = false
            self.process = nil
            self.resetReadiness()
            if shouldRestart {
                let message = "Cloudflare tunnel exited with status \(terminatedProcess.terminationStatus) while refreshing an unreachable setup link; restarting."
                self.diagnostics.record(message)
                DispatchQueue.main.async { [weak self] in
                    _ = self?.start(localPort: localPort)
                }
                return
            }
            if !wasStopping {
                let message = "Cloudflare tunnel exited with status \(terminatedProcess.terminationStatus)."
                self.diagnostics.record(message)
                self.diagnostics.uploadAutomaticIssueReport(
                    action: "remote_access_tunnel_exited",
                    reason: "tunnel_process_exited",
                    errorMessage: message,
                    context: self.tunnelDiagnosticsContext(
                        localPort: localPort,
                        binaryURL: binaryURL,
                        extra: [
                            "terminationStatus": Int(terminatedProcess.terminationStatus),
                            "terminationReason": String(describing: terminatedProcess.terminationReason)
                        ]
                    )
                )
            }
            DispatchQueue.main.async { self.urlHandler?(nil) }
        }

        do {
            try proc.run()
        } catch {
            let message = "Cloudflare tunnel process could not start. \(error.localizedDescription)"
            print("CloudflareTunnelManager: \(message)")
            diagnostics.record("Cloudflare tunnel process start failed: \(error.localizedDescription)")
            diagnostics.uploadAutomaticIssueReport(
                action: "remote_access_start_failed",
                reason: "tunnel_process_start_failed",
                errorMessage: message,
                context: tunnelDiagnosticsContext(localPort: localPort, binaryURL: binaryURL)
            )
            urlHandler?(nil)
            return false
        }
        self.process = proc
        diagnostics.record("Cloudflare tunnel started using \(binaryURL.path)")
        print("CloudflareTunnelManager: started cloudflared at \(binaryURL.path)")
        return true
    }

    func stop() {
        isStopping = true
        resetReadiness()
        process?.terminate()
        process = nil
        urlHandler?(nil)
    }

    private func publishURLWhenReady(_ url: String) {
        readinessQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            switch self.readinessGate.registerCandidate(url) {
            case .probe:
                self.probeTunnelURL(url, attempt: 1)
            case .ignore:
                break
            }
        }
    }

    private func probeTunnelURL(_ url: String, attempt: Int) {
        guard let probeURL = Self.webSocketProbeURL(from: url) else {
            publishReadyURL(url)
            return
        }

        let probe = TunnelWebSocketReadinessProbe(url: probeURL, timeout: 2.0)
        readinessProbe = probe
        probe.start { [weak self] isReady in
            self?.readinessQueue.async { [weak self] in
                guard let self else { return }
                guard self.readinessGate.isWaitingFor(url) else { return }

                if isReady {
                    self.publishReadyURL(url)
                    return
                }

                switch self.readinessGate.handleProbeFailure(for: url, tunnelIsRunning: self.isRunning) {
                case .retry(let pendingURL):
                    self.readinessProbe = nil
                    let delay = self.readinessRetryDelay(after: attempt)
                    self.readinessQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.probeTunnelURL(pendingURL, attempt: attempt + 1)
                    }
                case .stop:
                    self.readinessProbe = nil
                    DispatchQueue.main.async { [weak self] in self?.urlHandler?(nil) }
                case .restart(let pendingURL):
                    self.readinessProbe = nil
                    self.readinessGate.reset()
                    self.restartTunnelAfterUnreadyURL(pendingURL)
                case .ignore:
                    self.readinessProbe = nil
                }
            }
        }
    }

    private func readinessRetryDelay(after attempt: Int) -> TimeInterval {
        min(4.0, max(1.0, Double(attempt) * 0.5))
    }

    private func restartTunnelAfterUnreadyURL(_ url: String) {
        diagnostics.record("Cloudflare setup link did not become reachable; restarting tunnel for a fresh link.")
        guard isRunning else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                _ = self.start(localPort: self.activeLocalPort)
            }
            return
        }
        isRestartingAfterUnreadyURL = true
        process?.terminate()
    }

    private func publishReadyURL(_ url: String) {
        guard let readyURL = readinessGate.publishIfReady(url) else { return }
        readinessProbe = nil
        DispatchQueue.main.async { [weak self] in self?.urlHandler?(readyURL) }
    }

    private func resetReadiness() {
        readinessQueue.async { [weak self] in
            guard let self else { return }
            self.readinessProbe?.cancel()
            self.readinessProbe = nil
            self.readinessGate.reset()
        }
    }

    private func resetRecentOutput() {
        outputQueue.sync {
            recentOutputLines = []
        }
    }

    private func appendTunnelOutput(_ output: String) {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { Self.redactedTunnelOutputLine(String($0)) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        outputQueue.async { [weak self] in
            guard let self else { return }
            self.recentOutputLines.append(contentsOf: lines)
            if self.recentOutputLines.count > 20 {
                self.recentOutputLines.removeFirst(self.recentOutputLines.count - 20)
            }
        }
    }

    private func tunnelDiagnosticsContext(
        localPort: UInt16,
        binaryURL: URL? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var outputSnapshot: [String] = []
        outputQueue.sync {
            outputSnapshot = recentOutputLines
        }

        var context: [String: Any] = [
            "localPort": Int(localPort),
            "tunnelIsRunning": isRunning,
            "candidatePaths": cloudflaredURLs.map(\.path),
            "recentTunnelOutput": outputSnapshot
        ]

        if let binaryURL {
            context["binaryPath"] = binaryURL.path
        }

        extra.forEach { context[$0.key] = $0.value }
        return context
    }

    private static func webSocketProbeURL(from tunnelURL: String) -> URL? {
        guard var components = URLComponents(string: tunnelURL),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            components.scheme = scheme
        default:
            return nil
        }
        return components.url
    }

    private func extractURL(from output: String) -> String? {
        let patterns = ["https://[a-z0-9-]+\\.trycloudflare\\.com", "https://[a-z0-9-]+\\.cfargotunnel\\.com"]
        for pattern in patterns {
            if let range = output.range(of: pattern, options: .regularExpression) {
                return String(output[range])
            }
        }
        return nil
    }

    private static func redactedTunnelOutputLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "Bearer\\s+[A-Za-z0-9._~+/=-]+",
                with: "Bearer [redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "https?://[^\\s\"'<>]+",
                with: "[url]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b",
                with: "[email]",
                options: .regularExpression
            )
    }
}

enum TunnelURLReadinessAction: Equatable {
    case probe(String)
    case ignore
}

enum TunnelURLReadinessFailureAction: Equatable {
    case retry(String)
    case restart(String)
    case stop
    case ignore
}

struct TunnelURLReadinessGate {
    private var candidateURL: String?
    private var probeFailureCount = 0
    private let maximumProbeFailuresBeforeRestart: Int

    init(maximumProbeFailuresBeforeRestart: Int = 8) {
        self.maximumProbeFailuresBeforeRestart = max(1, maximumProbeFailuresBeforeRestart)
    }

    mutating func registerCandidate(_ url: String) -> TunnelURLReadinessAction {
        guard candidateURL != url else { return .ignore }
        candidateURL = url
        probeFailureCount = 0
        return .probe(url)
    }

    func isWaitingFor(_ url: String) -> Bool {
        candidateURL == url
    }

    mutating func handleProbeFailure(for url: String, tunnelIsRunning: Bool) -> TunnelURLReadinessFailureAction {
        guard candidateURL == url else { return .ignore }
        guard tunnelIsRunning else {
            candidateURL = nil
            probeFailureCount = 0
            return .stop
        }
        probeFailureCount += 1
        guard probeFailureCount < maximumProbeFailuresBeforeRestart else {
            return .restart(url)
        }
        return .retry(url)
    }

    mutating func publishIfReady(_ url: String) -> String? {
        guard candidateURL == url else { return nil }
        candidateURL = nil
        probeFailureCount = 0
        return url
    }

    mutating func reset() {
        candidateURL = nil
        probeFailureCount = 0
    }
}

private final class TunnelWebSocketReadinessProbe: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "airdesk.cloudflare.readiness.probe")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var timeoutWork: DispatchWorkItem?
    private var completion: ((Bool) -> Void)?
    private var hasCompleted = false

    init(url: URL, timeout: TimeInterval) {
        self.url = url
        self.timeout = timeout
    }

    func start(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.completion = completion
            let configuration = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: self.url)
            self.session = session
            self.task = task
            task.resume()

            let timeoutWork = DispatchWorkItem { [weak self] in
                self?.complete(false)
            }
            self.timeoutWork = timeoutWork
            self.queue.asyncAfter(deadline: .now() + self.timeout, execute: timeoutWork)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.complete(false)
        }
    }

    private func complete(_ isReady: Bool) {
        guard !hasCompleted else { return }
        hasCompleted = true
        timeoutWork?.cancel()
        timeoutWork = nil
        let completion = completion
        self.completion = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        completion?(isReady)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            self?.complete(true)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        queue.async { [weak self] in
            self?.complete(false)
        }
    }
}
