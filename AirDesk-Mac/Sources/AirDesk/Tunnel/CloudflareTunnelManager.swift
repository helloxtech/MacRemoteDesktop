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
    private var dnsReadinessProbe: TunnelDNSReadinessProbe?
    private var isStopping = false
    private var activeLocalPort: UInt16 = 7890
    private var recentOutputLines: [String] = []
    private var detectedFailure: CloudflareTunnelFailure?
    var urlHandler: ((String?) -> Void)?
    var failureHandler: ((CloudflareTunnelFailure) -> Void)?
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
            self.isStopping = false
            self.process = nil
            self.resetReadiness()
            let detectedFailure = self.detectedTunnelFailure(status: terminatedProcess.terminationStatus)
            if !wasStopping {
                let message = "Cloudflare tunnel exited with status \(terminatedProcess.terminationStatus)."
                let reportReason = detectedFailure?.reason ?? "tunnel_process_exited"
                let reportMessage = detectedFailure.map { "\(message) \($0.message)" } ?? message
                self.diagnostics.record(message)
                self.diagnostics.uploadAutomaticIssueReport(
                    action: "remote_access_tunnel_exited",
                    reason: reportReason,
                    errorMessage: reportMessage,
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
            DispatchQueue.main.async {
                self.urlHandler?(nil)
                if !wasStopping, let detectedFailure {
                    self.failureHandler?(detectedFailure)
                }
            }
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
                self.waitForTunnelDNS(url, attempt: 1)
            case .ignore:
                break
            }
        }
    }

    private func waitForTunnelDNS(_ url: String, attempt: Int) {
        guard let host = Self.tunnelHost(from: url) else {
            publishReadyURL(url)
            return
        }

        let probe = TunnelDNSReadinessProbe(host: host, timeout: 3.0)
        dnsReadinessProbe = probe
        probe.start { [weak self] isReady in
            self?.readinessQueue.async { [weak self] in
                guard let self else { return }
                guard self.readinessGate.isWaitingFor(url) else { return }

                self.dnsReadinessProbe = nil

                if isReady {
                    self.publishReadyURL(url)
                    return
                }

                switch self.readinessGate.handleProbeFailure(for: url, tunnelIsRunning: self.isRunning) {
                case .retry(let pendingURL):
                    let delay = self.readinessRetryDelay(after: attempt)
                    self.readinessQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.waitForTunnelDNS(pendingURL, attempt: attempt + 1)
                    }
                case .stop:
                    DispatchQueue.main.async { [weak self] in self?.urlHandler?(nil) }
                case .ignore:
                    break
                }
            }
        }
    }

    private func readinessRetryDelay(after attempt: Int) -> TimeInterval {
        min(4.0, max(1.0, Double(attempt) * 0.5))
    }

    private func publishReadyURL(_ url: String) {
        guard let readyURL = readinessGate.publishIfReady(url) else { return }
        dnsReadinessProbe = nil
        DispatchQueue.main.async { [weak self] in self?.urlHandler?(readyURL) }
    }

    private func resetReadiness() {
        readinessQueue.async { [weak self] in
            guard let self else { return }
            self.dnsReadinessProbe?.cancel()
            self.dnsReadinessProbe = nil
            self.readinessGate.reset()
        }
    }

    private func resetRecentOutput() {
        outputQueue.sync {
            recentOutputLines = []
            detectedFailure = nil
        }
    }

    private func appendTunnelOutput(_ output: String) {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { Self.redactedTunnelOutputLine(String($0)) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        outputQueue.sync {
            if let failure = CloudflareTunnelOutputFailureDetector.failure(from: lines) {
                detectedFailure = failure
            }
            recentOutputLines.append(contentsOf: lines)
            if recentOutputLines.count > 20 {
                recentOutputLines.removeFirst(recentOutputLines.count - 20)
            }
        }
    }

    private func detectedTunnelFailure(status: Int32) -> CloudflareTunnelFailure? {
        var failure: CloudflareTunnelFailure?
        outputQueue.sync {
            failure = detectedFailure
        }
        if let failure {
            return failure
        }
        guard status != 0 else { return nil }
        return CloudflareTunnelFailure(
            reason: "tunnel_process_exited",
            title: "Remote Access could not start",
            message: "The secure link helper stopped before AirDesk could create a setup link. Try again in a few minutes, then send diagnostics if it keeps failing."
        )
    }

    private func tunnelOutputSnapshot() -> [String] {
        var outputSnapshot: [String] = []
        outputQueue.sync {
            outputSnapshot = recentOutputLines
        }
        return outputSnapshot
    }

    private func tunnelDiagnosticsContext(
        localPort: UInt16,
        binaryURL: URL? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        let outputSnapshot = tunnelOutputSnapshot()

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

    private static func tunnelHost(from tunnelURL: String) -> String? {
        URLComponents(string: tunnelURL)?.host
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

struct CloudflareTunnelFailure: Equatable {
    let reason: String
    let title: String
    let message: String
}

struct CloudflareTunnelOutputFailureDetector {
    static func failure(from lines: [String]) -> CloudflareTunnelFailure? {
        let output = lines.joined(separator: "\n").lowercased()
        if output.contains("429 too many requests")
            || output.contains("error code: 1015")
            || output.contains("too many requests") {
            return CloudflareTunnelFailure(
                reason: "quick_tunnel_rate_limited",
                title: "Remote Access is temporarily limited",
                message: "Cloudflare is temporarily limiting new setup links from this network. Wait a few minutes, then try again. AirDesk will not keep retrying in the background."
            )
        }
        return nil
    }
}

enum TunnelURLReadinessAction: Equatable {
    case probe(String)
    case ignore
}

enum TunnelURLReadinessFailureAction: Equatable {
    case retry(String)
    case stop
    case ignore
}

struct TunnelURLReadinessGate {
    private var candidateURL: String?

    mutating func registerCandidate(_ url: String) -> TunnelURLReadinessAction {
        guard candidateURL != url else { return .ignore }
        candidateURL = url
        return .probe(url)
    }

    func isWaitingFor(_ url: String) -> Bool {
        candidateURL == url
    }

    mutating func handleProbeFailure(for url: String, tunnelIsRunning: Bool) -> TunnelURLReadinessFailureAction {
        guard candidateURL == url else { return .ignore }
        guard tunnelIsRunning else {
            candidateURL = nil
            return .stop
        }
        return .retry(url)
    }

    mutating func publishIfReady(_ url: String) -> String? {
        guard candidateURL == url else { return nil }
        candidateURL = nil
        return url
    }

    mutating func reset() {
        candidateURL = nil
    }
}

struct TunnelDNSReadinessPayload {
    static func containsAddressRecord(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]] else {
            return false
        }

        return answers.contains { answer in
            guard let type = answer["type"] as? Int,
                  (type == 1 || type == 28),
                  let value = answer["data"] as? String else {
                return false
            }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private final class TunnelDNSReadinessProbe {
    private let host: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "airdesk.cloudflare.dns-readiness.probe")
    private var session: URLSession?
    private var tasks: [URLSessionDataTask] = []
    private var timeoutWork: DispatchWorkItem?
    private var completion: ((Bool) -> Void)?
    private var hasCompleted = false
    private var remainingRequests = 0

    init(host: String, timeout: TimeInterval) {
        self.host = host
        self.timeout = timeout
    }

    func start(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.completion = completion
            let session = URLSession(configuration: .ephemeral)
            self.session = session

            let recordTypes = ["A", "AAAA"]
            self.remainingRequests = recordTypes.count

            for recordType in recordTypes {
                guard let request = Self.request(host: self.host, recordType: recordType) else {
                    self.remainingRequests -= 1
                    continue
                }
                let task = session.dataTask(with: request) { [weak self] data, _, _ in
                    self?.queue.async {
                        self?.handleResponse(data)
                    }
                }
                tasks.append(task)
                task.resume()
            }

            if self.remainingRequests <= 0 {
                self.complete(false)
                return
            }

            let timeoutWork = DispatchWorkItem { [weak self] in
                self?.complete(false)
            }
            self.timeoutWork = timeoutWork
            self.queue.asyncAfter(deadline: .now() + self.timeout, execute: timeoutWork)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.hasCompleted else { return }
            self.hasCompleted = true
            self.timeoutWork?.cancel()
            self.timeoutWork = nil
            self.tasks.forEach { $0.cancel() }
            self.tasks = []
            self.session?.invalidateAndCancel()
            self.session = nil
            self.completion = nil
        }
    }

    private func handleResponse(_ data: Data?) {
        guard !hasCompleted else { return }
        if let data, TunnelDNSReadinessPayload.containsAddressRecord(data) {
            complete(true)
            return
        }

        remainingRequests -= 1
        if remainingRequests <= 0 {
            complete(false)
        }
    }

    private func complete(_ isReady: Bool) {
        guard !hasCompleted else { return }
        hasCompleted = true
        timeoutWork?.cancel()
        timeoutWork = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        session?.invalidateAndCancel()
        session = nil
        let completion = completion
        self.completion = nil
        completion?(isReady)
    }

    private static func request(host: String, recordType: String) -> URLRequest? {
        var components = URLComponents(string: "https://cloudflare-dns.com/dns-query")
        components?.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: recordType)
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 3.0
        return request
    }
}
