import Foundation

@main
struct RemoteTunnelReadinessGateTests {
    static func main() {
        testURLIsNotPublishedUntilProbeSucceeds()
        testStaleProbeSuccessIsIgnored()
        print("RemoteTunnelReadinessGateTests passed")
    }

    private static func testURLIsNotPublishedUntilProbeSucceeds() {
        var gate = TunnelURLReadinessGate()
        let url = "https://ready.trycloudflare.com"

        guard gate.registerCandidate(url) == .probe(url) else {
            fatalError("Expected candidate URL to request a readiness probe")
        }
        guard gate.publishIfReady(url) == url else {
            fatalError("Expected URL to publish only after readiness succeeds")
        }
        guard gate.publishIfReady(url) == nil else {
            fatalError("Expected URL not to publish twice")
        }
    }

    private static func testStaleProbeSuccessIsIgnored() {
        var gate = TunnelURLReadinessGate()
        let staleURL = "https://old.trycloudflare.com"
        let currentURL = "https://new.trycloudflare.com"

        _ = gate.registerCandidate(staleURL)
        _ = gate.registerCandidate(currentURL)

        guard gate.publishIfReady(staleURL) == nil else {
            fatalError("Expected stale readiness success to be ignored")
        }
        guard gate.publishIfReady(currentURL) == currentURL else {
            fatalError("Expected current URL to publish after readiness succeeds")
        }
    }
}
