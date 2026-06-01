import Foundation

enum WebSocketConnectionProgressAction: Equatable {
    case keepWaitingForScreenInfo
    case waitingForPairingCode
    case connected
}

enum ConnectionRetryPresentationState: Equatable {
    case connecting
    case reconnecting
}

enum ConnectionRetryPresentation {
    static func state(
        hasCompletedConnection: Bool,
        isAlreadyConnected: Bool,
        isAlreadyReconnecting: Bool,
        hasMonitorInfo: Bool
    ) -> ConnectionRetryPresentationState {
        if hasCompletedConnection || isAlreadyConnected || isAlreadyReconnecting || hasMonitorInfo {
            return .reconnecting
        }
        return .connecting
    }
}

enum ConnectionStatusKind {
    case localConnecting
    case remoteConnecting
    case reconnecting
}

struct ConnectionStatusContent: Equatable {
    let title: String
    let message: String
    let steps: [String]
}

enum ConnectionStatusPresentation {
    static func content(for kind: ConnectionStatusKind, hostName: String?) -> ConnectionStatusContent {
        let name = cleanHostName(hostName)

        switch kind {
        case .localConnecting:
            return ConnectionStatusContent(
                title: "Connecting to \(name)",
                message: "Checking the local connection and preparing the Mac screen.",
                steps: ["Opening connection", "Verifying pairing", "Loading Mac screen"]
            )
        case .remoteConnecting:
            return ConnectionStatusContent(
                title: "Opening Remote Access",
                message: "Using the secure link from \(name). This can take a little longer the first time.",
                steps: ["Opening secure link", "Verifying pairing", "Loading Mac screen"]
            )
        case .reconnecting:
            return ConnectionStatusContent(
                title: "Reconnecting to \(name)",
                message: "The connection dropped. AirDesk is retrying and will bring the Mac screen back here.",
                steps: ["Reopening connection", "Restoring session", "Refreshing Mac screen"]
            )
        }
    }

    private static func cleanHostName(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "your Mac" : trimmed
    }
}

enum RemoteCanvasPresentation {
    static func shouldShowNativeCanvas(hasMonitorInfo: Bool, hasReceivedFrame: Bool) -> Bool {
        hasMonitorInfo && hasReceivedFrame
    }
}

struct WebSocketConnectionProgress {
    private(set) var didOpenSocket = false
    private(set) var didReceivePairedStatus = false
    private(set) var didReceiveScreenInfo = false

    mutating func webSocketDidOpen() {
        didOpenSocket = true
    }

    mutating func pairingStatusReceived(paired: Bool) -> WebSocketConnectionProgressAction {
        guard paired else { return .waitingForPairingCode }
        didReceivePairedStatus = true
        return .keepWaitingForScreenInfo
    }

    mutating func screenInfoReceived(monitorCount: Int) -> WebSocketConnectionProgressAction {
        guard monitorCount > 0 else {
            return .keepWaitingForScreenInfo
        }
        didReceiveScreenInfo = true
        return .connected
    }
}
