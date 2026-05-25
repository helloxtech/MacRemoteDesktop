import Foundation
import AirDeskProtocol

@MainActor
final class LockStatusMonitor {
    static let shared = LockStatusMonitor()

    private(set) var isLocked = false
    private var observers: [Any] = []

    private init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(isLocked: true)
            }
        })
        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(isLocked: false)
            }
        })
    }

    private func update(isLocked: Bool) {
        self.isLocked = isLocked
        NotificationCenter.default.post(name: .screenLockStatusChanged, object: isLocked)
    }
}

extension Notification.Name {
    static let screenLockStatusChanged = Notification.Name("screenLockStatusChanged")
}
