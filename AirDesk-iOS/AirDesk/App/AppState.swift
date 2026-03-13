import Foundation
import Combine
import UIKit

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
    @Published var decodedFPS: Double = 0

    private(set) var webSocketClient: WebSocketClient?
    private var discovery: BonjourDiscovery?
    private var videoDecoders: [Int: VideoDecoder] = [:]
    private let decoderQueue = DispatchQueue(label: "airdesk.decoder")

    // Keyed by displayIndex — fixes the single-handler overwrite bug for multi-monitor
    private var frameUpdateHandlers: [Int: (CVPixelBuffer) -> Void] = [:]

    // FPS tracking
    private var fpsFrameCount = 0
    private var fpsWindowStart = Date()

    func startDiscovery() {
        let d = BonjourDiscovery()
        d.hostsUpdated = { [weak self] hosts in
            Task { @MainActor in self?.discoveredHosts = hosts }
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

        // Video frames arrive on URLSession background thread — decode off main actor
        client.onVideoFrame = { [weak self] data, displayIndex, isKeyframe, timestampMs in
            guard let self else { return }
            self.decoderQueue.async {
                self.decodeFrame(data, displayIndex: displayIndex, isKeyframe: isKeyframe, timestampMs: timestampMs)
            }
        }

        client.onDisconnect = { [weak self] error in
            Task { @MainActor in
                self?.connectionState = .disconnected
                self?.monitors = []
                self?.errorMessage = error?.localizedDescription
                self?.frameUpdateHandlers.removeAll()
                self?.videoDecoders.removeAll()
            }
        }

        client.onClipboardChanged = { text in
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        }

        client.onLatencyUpdate = { [weak self] ms in
            Task { @MainActor in self?.latencyMs = ms }
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
        latencyMs = 0
        decodedFPS = 0
        frameUpdateHandlers.removeAll()
        videoDecoders.removeAll()
    }

    func selectMonitor(_ index: Int) {
        activeMonitorIndex = index
        webSocketClient?.requestStream(displayIndex: index)
    }

    func pushClipboardToMac() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        webSocketClient?.sendClipboard(text)
    }

    /// MonitorView registers itself for a specific display index
    func registerFrameHandler(displayIndex: Int, handler: @escaping (CVPixelBuffer) -> Void) {
        frameUpdateHandlers[displayIndex] = handler
    }

    // Called on decoderQueue
    private func decodeFrame(_ data: Data, displayIndex: Int, isKeyframe: Bool, timestampMs: UInt32) {
        if videoDecoders[displayIndex] == nil {
            let decoder = VideoDecoder(displayIndex: displayIndex)
            decoder.frameHandler = { [weak self] pixelBuffer, idx in
                guard let self else { return }
                self.tickFPS()
                Task { @MainActor in self.frameUpdateHandlers[idx]?(pixelBuffer) }
            }
            videoDecoders[displayIndex] = decoder
        }
        videoDecoders[displayIndex]?.decode(data, isKeyframe: isKeyframe)
    }

    // Called on decoderQueue from frameHandler
    private func tickFPS() {
        fpsFrameCount += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            let fps = Double(fpsFrameCount) / elapsed
            fpsFrameCount = 0
            fpsWindowStart = Date()
            Task { @MainActor in self.decodedFPS = fps }
        }
    }
}
