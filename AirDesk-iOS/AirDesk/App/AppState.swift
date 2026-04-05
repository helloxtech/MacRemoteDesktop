import Foundation
import Combine
import UIKit

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

/// Thread-safe frame relay — delivers CVPixelBuffers directly to renderers
/// without routing through @MainActor. Prevents pixel buffer pool exhaustion
/// when the main thread is busy (keyboard animation, SwiftUI layout, screen switch).
final class FrameRelay {
    static let shared = FrameRelay()

    private var handlers: [Int: (CVPixelBuffer) -> Void] = [:]
    private let lock = NSLock()

    func set(displayIndex: Int, handler: ((CVPixelBuffer) -> Void)?) {
        lock.lock()
        handlers[displayIndex] = handler
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        handlers.removeAll()
        lock.unlock()
    }

    /// Delivers frame directly to handler (thread-safe). Returns true if delivered.
    func deliver(_ pixelBuffer: CVPixelBuffer, displayIndex: Int) -> Bool {
        lock.lock()
        let handler = handlers[displayIndex]
        lock.unlock()
        handler?(pixelBuffer)
        return handler != nil
    }
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
    @Published var isHostLocked: Bool = false
    @Published var hostStatusMessage: String?

    private(set) var webSocketClient: WebSocketClient?
    private var discovery: BonjourDiscovery?
    private var videoDecoders: [Int: VideoDecoder] = [:]
    private let decoderQueue = DispatchQueue(label: "airdesk.decoder")

    // Keyed by displayIndex — fixes the single-handler overwrite bug for multi-monitor
    private var frameUpdateHandlers: [Int: (CVPixelBuffer) -> Void] = [:]
    // Weak ref to the active MonitorViewController for zoom toggle from toolbar
    weak var activeMonitorVC: MonitorViewController?
    // Frames decoded before the MonitorView handler is registered
    private var pendingFrames: [Int: CVPixelBuffer] = [:]

    // FPS tracking — uses CFAbsoluteTime to avoid Date() allocation per frame
    private var fpsFrameCount = 0
    private var fpsWindowStart: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastReportedLatency: Int = -1

    func startDiscovery() {
        discovery?.stop()
        discoveredHosts = []
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
                let currentIndex = self?.activeMonitorIndex ?? 0
                self?.monitors = monitors
                if !monitors.contains(where: { $0.id == currentIndex }) {
                    self?.activeMonitorIndex = monitors.first?.id ?? 0
                }
                self?.connectionState = .connected
                self?.requestFreshFrames()
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
            FrameRelay.shared.removeAll()
            Task { @MainActor in
                self?.connectionState = .disconnected
                self?.monitors = []
                self?.activeMonitorIndex = 0
                self?.errorMessage = error?.localizedDescription
                self?.latencyMs = 0
                self?.decodedFPS = 0
                self?.isHostLocked = false
                self?.hostStatusMessage = nil
                self?.lastReportedLatency = -1
                self?.frameUpdateHandlers.removeAll()
                self?.pendingFrames.removeAll()
                self?.videoDecoders.removeAll()
            }
        }

        client.onClipboardChanged = { text in
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        }

        client.onLatencyUpdate = { [weak self] ms in
            guard let self, ms != self.lastReportedLatency else { return }
            self.lastReportedLatency = ms
            Task { @MainActor in self.latencyMs = ms }
        }

        client.onLockStatusChanged = { [weak self] isLocked, message in
            Task { @MainActor in
                self?.isHostLocked = isLocked
                self?.hostStatusMessage = isLocked
                    ? "Mac is locked. Password entry may not be visible until the Mac unlocks."
                    : nil
                if !isLocked {
                    self?.requestFreshFrames()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.requestFreshFrames()
                    }
                } else if self?.hostStatusMessage == nil {
                    self?.hostStatusMessage = message
                }
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
        activeMonitorIndex = 0
        selectedHost = nil
        latencyMs = 0
        decodedFPS = 0
        isHostLocked = false
        hostStatusMessage = nil
        lastReportedLatency = -1
        FrameRelay.shared.removeAll()
        frameUpdateHandlers.removeAll()
        pendingFrames.removeAll()
        videoDecoders.removeAll()
        startDiscovery()  // restart scan so the list is fresh when returning to ConnectionView
    }

    func selectMonitor(_ index: Int) {
        // Remove old frame handler so the old VC can be fully released
        let oldIndex = activeMonitorIndex
        if oldIndex != index {
            FrameRelay.shared.set(displayIndex: oldIndex, handler: nil)
            frameUpdateHandlers.removeValue(forKey: oldIndex)
            pendingFrames.removeValue(forKey: oldIndex)
        }
        activeMonitorIndex = index
        webSocketClient?.requestStream(displayIndex: index)
    }

    func pushClipboardToMac() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        webSocketClient?.sendClipboard(text)
    }

    /// MonitorView registers itself for a specific display index.
    /// Also requests the stream so the Mac sends frames + a keyframe for this display.
    func registerFrameHandler(displayIndex: Int, handler: @escaping (CVPixelBuffer) -> Void) {
        // Register in thread-safe FrameRelay for direct delivery (bypasses @MainActor)
        FrameRelay.shared.set(displayIndex: displayIndex, handler: handler)
        frameUpdateHandlers[displayIndex] = handler
        // Deliver any frame that was decoded before this handler was registered
        if let pending = pendingFrames.removeValue(forKey: displayIndex) {
            handler(pending)
        }
        if connectionState == .connected {
            webSocketClient?.requestStream(displayIndex: displayIndex)
        }
    }

    // Called on decoderQueue
    private func decodeFrame(_ data: Data, displayIndex: Int, isKeyframe: Bool, timestampMs: UInt32) {
        if videoDecoders[displayIndex] == nil {
            let decoder = VideoDecoder(displayIndex: displayIndex)
            decoder.frameHandler = { [weak self] pixelBuffer, idx in
                guard let self else { return }
                self.tickFPS()
                // Deliver directly to renderer via FrameRelay (thread-safe, no @MainActor).
                // This prevents CVPixelBuffer pile-up when the main thread is busy
                // (keyboard animation, SwiftUI layout during screen switch).
                if !FrameRelay.shared.deliver(pixelBuffer, displayIndex: idx) {
                    // No handler registered yet — store for later (rare, only during initial connect)
                    Task { @MainActor in
                        self.pendingFrames[idx] = pixelBuffer
                    }
                }
            }
            videoDecoders[displayIndex] = decoder
        }
        videoDecoders[displayIndex]?.decode(data, isKeyframe: isKeyframe)
    }

    // Called on decoderQueue from frameHandler
    private func tickFPS() {
        fpsFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsWindowStart
        if elapsed >= 1.0 {
            let fps = Double(fpsFrameCount) / elapsed
            fpsFrameCount = 0
            fpsWindowStart = now
            Task { @MainActor in self.decodedFPS = fps }
        }
    }

    private func requestFreshFrames() {
        guard connectionState == .connected else { return }
        if monitors.contains(where: { $0.id == activeMonitorIndex }) {
            webSocketClient?.requestStream(displayIndex: activeMonitorIndex)
        }
        for monitor in monitors where monitor.id != activeMonitorIndex {
            webSocketClient?.requestStream(displayIndex: monitor.id)
        }
    }
}
