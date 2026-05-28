import Foundation

class CloudflareTunnelManager {

    private var process: Process?
    private let readinessQueue = DispatchQueue(label: "airdesk.cloudflare.readiness")
    private var readinessGate = TunnelURLReadinessGate()
    private var readinessProbe: TunnelWebSocketReadinessProbe?
    var urlHandler: ((String?) -> Void)?
    var isRunning: Bool {
        process?.isRunning == true
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
        guard let binaryURL = cloudflaredURLs.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            print("CloudflareTunnelManager: cloudflared helper not found or not executable")
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
            if let url = self?.extractURL(from: output) {
                self?.publishURLWhenReady(url)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            self?.resetReadiness()
            DispatchQueue.main.async { self?.urlHandler?(nil) }
        }

        do {
            try proc.run()
        } catch {
            print("CloudflareTunnelManager: failed to start cloudflared: \(error)")
            urlHandler?(nil)
            return false
        }
        self.process = proc
        print("CloudflareTunnelManager: started cloudflared at \(binaryURL.path)")
        return true
    }

    func stop() {
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
                case .publish(let pendingURL):
                    self.publishReadyURL(pendingURL)
                case .stop:
                    self.readinessProbe = nil
                    DispatchQueue.main.async { [weak self] in self?.urlHandler?(nil) }
                case .ignore:
                    self.readinessProbe = nil
                }
            }
        }
    }

    private func readinessRetryDelay(after attempt: Int) -> TimeInterval {
        min(4.0, max(1.0, Double(attempt) * 0.5))
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
}

enum TunnelURLReadinessAction: Equatable {
    case probe(String)
    case ignore
}

enum TunnelURLReadinessFailureAction: Equatable {
    case retry(String)
    case publish(String)
    case stop
    case ignore
}

struct TunnelURLReadinessGate {
    private let maximumProbeFailuresBeforeFallback: Int
    private var candidateURL: String?
    private var probeFailureCount = 0

    init(maximumProbeFailuresBeforeFallback: Int = 3) {
        self.maximumProbeFailuresBeforeFallback = max(1, maximumProbeFailuresBeforeFallback)
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
        guard probeFailureCount < maximumProbeFailuresBeforeFallback else {
            return .publish(url)
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
