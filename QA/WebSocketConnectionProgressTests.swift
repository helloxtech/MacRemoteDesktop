import Foundation

@main
struct WebSocketConnectionProgressTests {
    static func main() {
        testPairedStatusStillWaitsForScreenInfo()
        testUnpairedStatusStopsWaitingForUserInput()
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
}
