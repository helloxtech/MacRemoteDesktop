import Foundation

enum RemoteAccessPlan: String, CaseIterable, Identifiable {
    case free
    case pro
    case power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        case .power: return "Power"
        }
    }

    var productID: String? {
        switch self {
        case .free: return nil
        case .pro: return "com.helloxtech.airdesk.remote.pro.monthly"
        case .power: return "com.helloxtech.airdesk.remote.power.monthly"
        }
    }

    var fallbackPriceText: String {
        switch self {
        case .free: return "$0"
        case .pro: return "$2.99/month"
        case .power: return "$6.99/month"
        }
    }

    var monthlyRemoteAccessLimitSeconds: Int {
        switch self {
        case .free: return 0
        case .pro: return 20 * 60 * 60
        case .power: return 100 * 60 * 60
        }
    }

    var includedRemoteHoursText: String {
        switch self {
        case .free: return "Local Wi-Fi only"
        case .pro: return "20 remote hours/month"
        case .power: return "100 remote hours/month"
        }
    }

    var allowsRemoteAccess: Bool {
        monthlyRemoteAccessLimitSeconds > 0
    }
}

final class RemoteAccessUsageLedger {
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let keyPrefix = "airdesk.remoteAccess.usageSeconds"

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    func usedSeconds(at date: Date = Date()) -> Int {
        defaults.integer(forKey: key(for: date))
    }

    func addUsage(seconds: Int, at date: Date = Date()) {
        guard seconds > 0 else { return }
        let usageKey = key(for: date)
        let current = defaults.integer(forKey: usageKey)
        defaults.set(current + seconds, forKey: usageKey)
    }

    func remainingSeconds(for plan: RemoteAccessPlan, at date: Date = Date()) -> Int {
        max(0, plan.monthlyRemoteAccessLimitSeconds - usedSeconds(at: date))
    }

    func canStartRemoteAccess(plan: RemoteAccessPlan, at date: Date = Date()) -> Bool {
        plan.allowsRemoteAccess && remainingSeconds(for: plan, at: date) > 0
    }

    private func key(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        return "\(keyPrefix).\(String(format: "%04d-%02d", year, month))"
    }
}

struct RemoteAccessPaywallPresentation: Identifiable {
    enum Reason {
        case subscriptionRequired
        case monthlyLimitReached
    }

    let id = UUID()
    let reason: Reason

    var message: String {
        switch reason {
        case .subscriptionRequired:
            return "Remote Access is included with Pro or Power. Local Wi-Fi connections remain free."
        case .monthlyLimitReached:
            return "You have used this month’s Remote Access time for your current plan. Upgrade to Power for more time."
        }
    }
}

struct RemoteAccessUsageSummary {
    let plan: RemoteAccessPlan
    let usedSeconds: Int
    let remainingSeconds: Int
    let canStart: Bool

    var usedText: String {
        Self.timeText(seconds: usedSeconds)
    }

    var remainingText: String {
        guard plan.allowsRemoteAccess else { return "Remote locked" }
        return Self.timeText(seconds: remainingSeconds)
    }

    private static func timeText(seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let hours = safeSeconds / 3_600
        let minutes = (safeSeconds % 3_600) / 60
        if hours == 0 {
            return "\(minutes)m"
        }
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }
}
