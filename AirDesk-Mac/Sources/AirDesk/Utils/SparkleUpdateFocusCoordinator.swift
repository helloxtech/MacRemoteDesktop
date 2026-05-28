import Foundation

struct SparkleUpdateFocusPlan {
    let focusPassDelays: [TimeInterval]

    init(focusPassDelays: [TimeInterval] = [0.0, 0.1, 0.35, 0.8]) {
        self.focusPassDelays = focusPassDelays
    }

    func shouldPromoteWindow(title: String, isVisible: Bool) -> Bool {
        guard isVisible else { return false }
        let normalizedTitle = title.lowercased()
        return normalizedTitle == "airdesk"
            || normalizedTitle.contains("update")
            || normalizedTitle.contains("new version")
            || normalizedTitle.contains("version of airdesk")
    }
}
