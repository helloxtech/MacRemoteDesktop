import Foundation

func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Assertion failed: \(message)\n", stderr)
        exit(1)
    }
}

func testThrottleAllowsFirstReport() {
    let throttle = AutomaticIssueReportThrottle(interval: 600)
    let now = Date(timeIntervalSince1970: 1_800)

    assert(throttle.shouldSend(lastSentAt: nil, now: now), "First automatic report should send")
}

func testThrottleBlocksRepeatedReportInsideInterval() {
    let throttle = AutomaticIssueReportThrottle(interval: 600)
    let lastSentAt = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 1_599)

    assert(!throttle.shouldSend(lastSentAt: lastSentAt, now: now), "Repeated report should be throttled")
}

func testThrottleAllowsReportAfterInterval() {
    let throttle = AutomaticIssueReportThrottle(interval: 600)
    let lastSentAt = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 1_600)

    assert(throttle.shouldSend(lastSentAt: lastSentAt, now: now), "Report should send after interval")
}

@main
struct AutomaticIssueReportThrottleTestRunner {
    static func main() {
        testThrottleAllowsFirstReport()
        testThrottleBlocksRepeatedReportInsideInterval()
        testThrottleAllowsReportAfterInterval()
        print("AutomaticIssueReportThrottleTests passed")
    }
}
