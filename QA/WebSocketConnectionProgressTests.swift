import Foundation

@main
struct WebSocketConnectionProgressTests {
    static func main() {
        testPairedStatusStillWaitsForScreenInfo()
        testEmptyScreenInfoStillWaitsForRealMonitorMetadata()
        testUnpairedStatusStopsWaitingForUserInput()
        testInitialRetryStaysInConnectingState()
        testRetryAfterCompletedConnectionShowsReconnectingState()
        testRemoteCanvasWaitsForFirstDecodedFrame()
        testRemoteConnectingPresentationUsesHelpfulCopy()
        print("WebSocketConnectionProgressTests passed")
    }

    private static func testPairedStatusStillWaitsForScreenInfo() {
        var progress = WebSocketConnectionProgress()
        progress.webSocketDidOpen()

        guard progress.pairingStatusReceived(paired: true) == .keepWaitingForScreenInfo else {
            fatalError("Expected paired status to keep the connect timeout active until screen info arrives")
        }
        guard progress.screenInfoReceived(monitorCount: 1) == .connected else {
            fatalError("Expected screen info to complete the connection")
        }
    }

    private static func testEmptyScreenInfoStillWaitsForRealMonitorMetadata() {
        var progress = WebSocketConnectionProgress()
        progress.webSocketDidOpen()
        _ = progress.pairingStatusReceived(paired: true)

        guard progress.screenInfoReceived(monitorCount: 0) == .keepWaitingForScreenInfo else {
            fatalError("Expected empty screen info to keep waiting for real monitor metadata")
        }
        guard progress.didReceiveScreenInfo == false else {
            fatalError("Expected empty screen info not to mark the connection complete")
        }
        guard progress.screenInfoReceived(monitorCount: 2) == .connected else {
            fatalError("Expected non-empty screen info to complete the connection")
        }
    }

    private static func testUnpairedStatusStopsWaitingForUserInput() {
        var progress = WebSocketConnectionProgress()
        progress.webSocketDidOpen()

        guard progress.pairingStatusReceived(paired: false) == .waitingForPairingCode else {
            fatalError("Expected unpaired status to stop the connect timeout while waiting for user input")
        }
    }

    private static func testInitialRetryStaysInConnectingState() {
        let state = ConnectionRetryPresentation.state(
            hasCompletedConnection: false,
            isAlreadyConnected: false,
            isAlreadyReconnecting: false,
            hasMonitorInfo: false
        )

        guard state == .connecting else {
            fatalError("Expected first-attempt retry to keep the Connecting presentation")
        }
    }

    private static func testRetryAfterCompletedConnectionShowsReconnectingState() {
        let state = ConnectionRetryPresentation.state(
            hasCompletedConnection: true,
            isAlreadyConnected: false,
            isAlreadyReconnecting: false,
            hasMonitorInfo: false
        )

        guard state == .reconnecting else {
            fatalError("Expected retry after a completed session to show Reconnecting")
        }
    }

    private static func testRemoteCanvasWaitsForFirstDecodedFrame() {
        guard RemoteCanvasPresentation.shouldShowNativeCanvas(hasMonitorInfo: true, hasReceivedFrame: false) == false else {
            fatalError("Expected monitor metadata alone not to show the native remote canvas")
        }
        guard RemoteCanvasPresentation.shouldShowNativeCanvas(hasMonitorInfo: true, hasReceivedFrame: true) else {
            fatalError("Expected the native remote canvas after the first decoded frame")
        }
    }

    private static func testRemoteConnectingPresentationUsesHelpfulCopy() {
        let content = ConnectionStatusPresentation.content(
            for: .remoteConnecting,
            hostName: "Desk"
        )

        guard content.title == "Opening Remote Access" else {
            fatalError("Expected Remote Access connecting title, got \(content.title)")
        }
        guard content.message.contains("secure link") else {
            fatalError("Expected user-friendly secure link message, got \(content.message)")
        }
        guard content.steps.count == 3 else {
            fatalError("Expected three visible progress steps")
        }
    }
}
