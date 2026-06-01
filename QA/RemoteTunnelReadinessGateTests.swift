import Foundation

@main
struct RemoteTunnelReadinessGateTests {
    static func main() {
        testURLIsNotPublishedUntilProbeSucceeds()
        testStaleProbeSuccessIsIgnored()
        testProbeFailureKeepsWaitingWhileTunnelIsRunning()
        testRepeatedProbeFailuresRestartTheTunnel()
        testRegisteringNewCandidateResetsRestartThreshold()
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

    private static func testProbeFailureKeepsWaitingWhileTunnelIsRunning() {
        var gate = TunnelURLReadinessGate()
        let url = "https://slow-dns.trycloudflare.com"

        _ = gate.registerCandidate(url)

        guard gate.handleProbeFailure(for: url, tunnelIsRunning: true) == .retry(url) else {
            fatalError("Expected a failed readiness probe to keep retrying while the tunnel process is running")
        }
        guard gate.publishIfReady(url) == url else {
            fatalError("Expected the same URL to remain pending after a transient probe failure")
        }
    }

    private static func testRepeatedProbeFailuresRestartTheTunnel() {
        var gate = TunnelURLReadinessGate(maximumProbeFailuresBeforeRestart: 3)
        let url = "https://probe-blocked.trycloudflare.com"

        _ = gate.registerCandidate(url)

        guard gate.handleProbeFailure(for: url, tunnelIsRunning: true) == .retry(url) else {
            fatalError("Expected the first failed readiness probe to retry")
        }
        guard gate.handleProbeFailure(for: url, tunnelIsRunning: true) == .retry(url) else {
            fatalError("Expected the second failed readiness probe to retry")
        }
        guard gate.handleProbeFailure(for: url, tunnelIsRunning: true) == .restart(url) else {
            fatalError("Expected repeated readiness failures to restart the tunnel instead of waiting forever")
        }
    }

    private static func testRegisteringNewCandidateResetsRestartThreshold() {
        var gate = TunnelURLReadinessGate(maximumProbeFailuresBeforeRestart: 2)
        let firstURL = "https://first.trycloudflare.com"
        let secondURL = "https://second.trycloudflare.com"

        _ = gate.registerCandidate(firstURL)

        guard gate.handleProbeFailure(for: firstURL, tunnelIsRunning: true) == .retry(firstURL) else {
            fatalError("Expected first candidate to retry after one failure")
        }

        _ = gate.registerCandidate(secondURL)

        guard gate.handleProbeFailure(for: secondURL, tunnelIsRunning: true) == .retry(secondURL) else {
            fatalError("Expected a new candidate URL to reset the failure count")
        }
        guard gate.handleProbeFailure(for: secondURL, tunnelIsRunning: true) == .restart(secondURL) else {
            fatalError("Expected the reset threshold to apply to the new candidate URL")
        }
    }
}
