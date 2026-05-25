import Foundation

class CloudflareTunnelManager {

    private var process: Process?
    var urlHandler: ((String?) -> Void)?
    var isRunning: Bool {
        process?.isRunning == true
    }

    private let cloudflaredPaths = [
        "/usr/local/bin/cloudflared",
        "/opt/homebrew/bin/cloudflared"
    ]

    @discardableResult
    func start(localPort: UInt16 = 7890) -> Bool {
        guard !isRunning else { return true }
        guard let binaryPath = cloudflaredPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("cloudflared not found. Install via: brew install cloudflare/cloudflare/cloudflared")
            urlHandler?(nil)
            return false
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["tunnel", "--url", "http://localhost:\(localPort)"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            if let url = self?.extractURL(from: output) {
                DispatchQueue.main.async { self?.urlHandler?(url) }
            }
        }

        proc.terminationHandler = { [weak self] _ in
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
        print("CloudflareTunnelManager: started cloudflared")
        return true
    }

    func stop() {
        process?.terminate()
        process = nil
        urlHandler?(nil)
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
