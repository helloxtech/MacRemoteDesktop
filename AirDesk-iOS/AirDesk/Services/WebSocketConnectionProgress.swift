import Foundation

enum WebSocketConnectionProgressAction: Equatable {
    case keepWaitingForScreenInfo
    case waitingForPairingCode
    case connected
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

    mutating func screenInfoReceived() -> WebSocketConnectionProgressAction {
        didReceiveScreenInfo = true
        return .connected
    }
}
