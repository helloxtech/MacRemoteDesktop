import Foundation

@main
struct WebSocketConnectionProgressTests {
    static func main() {
        testPairedStatusStillWaitsForScreenInfo()
        testUnpairedStatusStopsWaitingForUserInput()
        testInitialRetryStaysInConnectingState()
        testRetryAfterCompletedConnectionShowsReconnectingState()
        testRemoteConnectingPresentationUsesHelpfulCopy()
        print("WebSocketConnectionProgressTests passed")
    }

    private static func testPairedStatusStillWaitsForScreenInfo() {
        var progress = WebSocketConnectionProgress()
        progress.webSocketDidOpen()

        guard progress.pairingStatusReceived(paired: true) == .keepWaitingForScreenInfo else {
            fatalError("Expected paired status to keep the connect timeout active until screen info arrives")
        }
        guard progress.screenInfoReceived() == .connected else {
            fatalError("Expected screen info to complete the connection")
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
