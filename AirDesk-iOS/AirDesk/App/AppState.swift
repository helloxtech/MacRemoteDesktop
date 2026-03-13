import Foundation
import Combine

enum ConnectionState {
    case disconnected
    case connecting
    case connected
}

@MainActor
class AppState: ObservableObject {

    @Published var connectionState: ConnectionState = .disconnected
    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var selectedHost: DiscoveredHost?
    @Published var monitors: [MonitorInfo] = []
    @Published var activeMonitorIndex: Int = 0
    @Published var errorMessage: String?
    @Published var latencyMs: Int = 0

    private(set) var webSocketClient: WebSocketClient?
    private var discovery: BonjourDiscovery?
    private var videoDecoders: [Int: VideoDecoder] = [:]
    var frameUpdateHandler: ((CVPixelBuffer, Int) -> Void)?

    func startDiscovery() {
        let d = BonjourDiscovery()
        d.hostsUpdated = { [weak self] hosts in
            Task { @MainActor in
                self?.discoveredHosts = hosts
            }
        }
        d.start()
        discovery = d
    }

    func connect(to host: DiscoveredHost) {
        selectedHost = host
        connectionState = .connecting
        errorMessage = nil

        let client = WebSocketClient(host: host.host, port: host.port)
        client.onMonitorsReceived = { [weak self] monitors in
            Task { @MainActor in
                self?.monitors = monitors
                self?.connectionState = .connected
            }
        }
        client.onVideoFrame = { [weak self] data, displayIndex, isKeyframe in
            self?.handleVideoFrame(data, displayIndex: displayIndex, isKeyframe: isKeyframe)
        }
        client.onDisconnect = { [weak self] error in
            Task { @MainActor in
                self?.connectionState = .disconnected
                self?.monitors = []
                self?.errorMessage = error?.localizedDescription
            }
        }
        client.connect()
        webSocketClient = client
    }

    func disconnect() {
        webSocketClient?.disconnect()
        webSocketClient = nil
        connectionState = .disconnected
        monitors = []
        selectedHost = nil
        videoDecoders.removeAll()
    }

    func selectMonitor(_ index: Int) {
        activeMonitorIndex = index
        webSocketClient?.requestStream(displayIndex: index)
    }

    private func handleVideoFrame(_ data: Data, displayIndex: Int, isKeyframe: Bool) {
        if videoDecoders[displayIndex] == nil {
            let decoder = VideoDecoder(displayIndex: displayIndex)
            decoder.frameHandler = { [weak self] pixelBuffer, idx in
                self?.frameUpdateHandler?(pixelBuffer, idx)
            }
            videoDecoders[displayIndex] = decoder
        }
        videoDecoders[displayIndex]?.decode(data, isKeyframe: isKeyframe)
    }
}
