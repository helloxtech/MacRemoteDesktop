import Foundation

@main
struct RemoteAccessPlanTests {
    static func main() {
        testPlanLimits()
        testUsageReducesRemainingTime()
        testUsageResetsWhenMonthChanges()
        print("RemoteAccessPlanTests passed")
    }

    private static func testPlanLimits() {
        expect(!RemoteAccessPlan.free.allowsRemoteAccess, "Free should not allow Remote Access")
        expect(RemoteAccessPlan.pro.monthlyRemoteAccessLimitSeconds == 20 * 60 * 60, "Pro should include 20 remote hours")
        expect(RemoteAccessPlan.power.monthlyRemoteAccessLimitSeconds == 100 * 60 * 60, "Power should include 100 remote hours")
        expect(RemoteAccessPlan.pro.productID == "com.helloxtech.airdesk.remote.pro.monthly", "Pro product id should match App Store Connect")
        expect(RemoteAccessPlan.power.productID == "com.helloxtech.airdesk.remote.power.monthly", "Power product id should match App Store Connect")
    }

    private static func testUsageReducesRemainingTime() {
        let calendar = Calendar(identifier: .gregorian)
        let suiteName = "RemoteAccessPlanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ledger = RemoteAccessUsageLedger(defaults: defaults, calendar: calendar)
        let date = date(year: 2026, month: 5, day: 28, hour: 10)

        ledger.addUsage(seconds: 3_600, at: date)

        expect(ledger.usedSeconds(at: date) == 3_600, "Ledger should store usage in the current month")
        expect(ledger.remainingSeconds(for: .pro, at: date) == (20 * 60 * 60) - 3_600, "Pro remaining time should subtract used seconds")
        expect(ledger.canStartRemoteAccess(plan: .pro, at: date), "Pro should still be allowed while time remains")
    }

    private static func testUsageResetsWhenMonthChanges() {
        let calendar = Calendar(identifier: .gregorian)
        let suiteName = "RemoteAccessPlanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ledger = RemoteAccessUsageLedger(defaults: defaults, calendar: calendar)
        let may = date(year: 2026, month: 5, day: 28, hour: 10)
        let june = date(year: 2026, month: 6, day: 1, hour: 10)

        ledger.addUsage(seconds: 20 * 60 * 60, at: may)

        expect(!ledger.canStartRemoteAccess(plan: .pro, at: may), "Pro should be blocked after 20 hours in the same month")
        expect(ledger.usedSeconds(at: june) == 0, "New month should start with zero used seconds")
        expect(ledger.canStartRemoteAccess(plan: .pro, at: june), "Pro should be allowed again in the next month")
    }

    private static func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
