import Foundation

@main
struct RemoteTunnelReadinessGateTests {
    static func main() {
        testURLIsNotPublishedUntilProbeSucceeds()
        testStaleProbeSuccessIsIgnored()
        testProbeFailureKeepsWaitingWhileTunnelIsRunning()
        testRepeatedProbeFailuresKeepSameTunnel()
        testRegisteringNewCandidateResetsFailureHandling()
        testDNSReadinessAcceptsIPv6Answer()
        testDNSReadinessRejectsNoAddressAnswers()
        testRateLimitOutputCreatesUserFacingFailure()
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

    private static func testRepeatedProbeFailuresKeepSameTunnel() {
        var gate = TunnelURLReadinessGate()
        let url = "https://probe-blocked.trycloudflare.com"

        _ = gate.registerCandidate(url)

        guard gate.handleProbeFailure(for: url, tunnelIsRunning: true) == .retry(url) else {
            fatalError("Expected the first failed readiness probe to retry")
        }
        guard gate.handleProbeFailure(for: url, tunnelIsRunning: true) == .retry(url) else {
            fatalError("Expected the second failed readiness probe to retry")
        }
        guard gate.handleProbeFailure(for: url, tunnelIsRunning: true) == .retry(url) else {
            fatalError("Expected repeated readiness failures to keep the same quick tunnel URL instead of creating new tunnels")
        }
    }

    private static func testRegisteringNewCandidateResetsFailureHandling() {
        var gate = TunnelURLReadinessGate()
        let firstURL = "https://first.trycloudflare.com"
        let secondURL = "https://second.trycloudflare.com"

        _ = gate.registerCandidate(firstURL)

        guard gate.handleProbeFailure(for: firstURL, tunnelIsRunning: true) == .retry(firstURL) else {
            fatalError("Expected first candidate to retry after one failure")
        }

        _ = gate.registerCandidate(secondURL)

        guard gate.handleProbeFailure(for: secondURL, tunnelIsRunning: true) == .retry(secondURL) else {
            fatalError("Expected a new candidate URL to retry independently")
        }
    }

    private static func testDNSReadinessAcceptsIPv6Answer() {
        let payload = Data("""
        {
          "Status": 0,
          "Answer": [
            { "name": "ready.trycloudflare.com", "type": 28, "TTL": 300, "data": "2606:4700::6810:e684" }
          ]
        }
        """.utf8)

        guard TunnelDNSReadinessPayload.containsAddressRecord(payload) else {
            fatalError("Expected an IPv6 DNS answer to mark the tunnel hostname as ready")
        }
    }

    private static func testDNSReadinessRejectsNoAddressAnswers() {
        let payload = Data("""
        {
          "Status": 0,
          "Question": [
            { "name": "waiting.trycloudflare.com", "type": 28 }
          ]
        }
        """.utf8)

        guard !TunnelDNSReadinessPayload.containsAddressRecord(payload) else {
            fatalError("Expected a DNS response without A or AAAA answers to remain not ready")
        }
    }

    private static func testRateLimitOutputCreatesUserFacingFailure() {
        let failure = CloudflareTunnelOutputFailureDetector.failure(from: [
            #"ERR Error unmarshaling QuickTunnel response: error code: 1015 status_code="429 Too Many Requests""#
        ])

        guard failure?.reason == "quick_tunnel_rate_limited" else {
            fatalError("Expected Cloudflare 429 output to create a specific rate-limit failure")
        }
        guard failure?.message.contains("Wait a few minutes") == true else {
            fatalError("Expected rate-limit failure to include a user-facing retry instruction")
        }
    }
}
