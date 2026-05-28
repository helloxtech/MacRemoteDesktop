import Foundation

@main
struct SparkleUpdateFocusTests {
    static func main() {
        testFocusPassesRetryAfterSparkleCreatesWindow()
        testOnlyLikelyUpdateWindowsArePromoted()
        print("SparkleUpdateFocusTests passed")
    }

    private static func testFocusPassesRetryAfterSparkleCreatesWindow() {
        let plan = SparkleUpdateFocusPlan()

        expect(plan.focusPassDelays == [0.0, 0.1, 0.35, 0.8], "focus passes should retry after Sparkle creates and orders its window")
    }

    private static func testOnlyLikelyUpdateWindowsArePromoted() {
        let plan = SparkleUpdateFocusPlan()

        expect(plan.shouldPromoteWindow(title: "AirDesk", isVisible: true), "Sparkle update window may use the app name as its title")
        expect(plan.shouldPromoteWindow(title: "A new version of AirDesk is available!", isVisible: true), "AirDesk update window should be promoted")
        expect(plan.shouldPromoteWindow(title: "Software Update", isVisible: true), "generic update window should be promoted")
        expect(!plan.shouldPromoteWindow(title: "Starting Remote Access", isVisible: true), "Remote Access window should not be treated as a Sparkle update window")
        expect(!plan.shouldPromoteWindow(title: "A new version of AirDesk is available!", isVisible: false), "hidden update windows should not be promoted")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fatalError(message)
        }
    }
}
