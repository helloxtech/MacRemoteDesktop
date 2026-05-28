import Foundation
import Combine
import UIKit
import AirDeskProtocol

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case reconnecting
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

final class FrameDecoderStore {
    var onFPSUpdate: ((Double) -> Void)?
    var onPendingFrame: ((CVPixelBuffer, Int) -> Void)?
    var onRecoveryKeyframeNeeded: ((Int) -> Void)?

    private var videoDecoders: [Int: VideoDecoder] = [:]
    private let queue = DispatchQueue(label: "airdesk.decoder")
    private var fpsFrameCount = 0
    private var fpsWindowStart: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    func decode(_ data: Data, payloadOffset: Int, displayIndex: Int, isKeyframe: Bool) {
        queue.async { [weak self] in
            self?.decodeFrame(data, payloadOffset: payloadOffset, displayIndex: displayIndex, isKeyframe: isKeyframe)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.videoDecoders.values.forEach { $0.close() }
            self.videoDecoders.removeAll()
            self.fpsFrameCount = 0
            self.fpsWindowStart = CFAbsoluteTimeGetCurrent()
        }
    }

    private func decodeFrame(_ data: Data, payloadOffset: Int, displayIndex: Int, isKeyframe: Bool) {
        if videoDecoders[displayIndex] == nil {
            let decoder = VideoDecoder(displayIndex: displayIndex)
            decoder.frameHandler = { [weak self] pixelBuffer, idx in
                self?.handleDecodedFrame(pixelBuffer, displayIndex: idx)
            }
            decoder.recoveryHandler = { [weak self] idx in
                self?.onRecoveryKeyframeNeeded?(idx)
            }
            videoDecoders[displayIndex] = decoder
        }
        videoDecoders[displayIndex]?.decode(data, payloadOffset: payloadOffset, isKeyframe: isKeyframe)
    }

    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer, displayIndex: Int) {
        tickFPS()
        if !FrameRelay.shared.deliver(pixelBuffer, displayIndex: displayIndex) {
            onPendingFrame?(pixelBuffer, displayIndex)
        }
    }

    private func tickFPS() {
        fpsFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsWindowStart
        if elapsed >= 1.0 {
            let fps = Double(fpsFrameCount) / elapsed
            fpsFrameCount = 0
            fpsWindowStart = now
            onFPSUpdate?(fps)
        }
    }
}

@MainActor
class AppState: ObservableObject {

    @Published var connectionState: ConnectionState = .disconnected
    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var selectedHost: DiscoveredHost?
    @Published var sessionMode: ConnectionMode?
    @Published var monitors: [MonitorInfo] = []
    @Published var activeMonitorIndex: Int = 0
    @Published var errorMessage: String?
    @Published var latencyMs: Int = 0
    @Published var decodedFPS: Double = 0
    @Published var isHostLocked: Bool = false
    @Published var hostStatusMessage: String?
    @Published var permissionStatus: PermissionStatusMessage = .controlReady
    @Published var vncFramebufferImage: CGImage?
    @Published var vncFramebufferSize: CGSize = .zero
    @Published var vncFramebufferImageSize: CGSize = .zero
    @Published var vncFramebufferImageCoversSelectedDisplay = false
    @Published var vncHasFramebuffer = false
    @Published var vncFrameRevision: Int = 0
    @Published var vncDisplays: [VNCDisplayInfo] = []
    @Published var activeVNCDisplayID: UInt32?
    @Published var pairingChallenge: PairingChallenge?

    let connectionDraft = ConnectionDraft()
    let remoteConnectionStore = SavedRemoteConnectionStore()
    private(set) var webSocketClient: WebSocketClient?
    private(set) var vncSessionController: VNCSessionController?
    private var discovery: BonjourDiscovery?
    private let frameDecoderStore = FrameDecoderStore()
    private var pendingPairingRequest: ConnectionRequest?

    // Keyed by displayIndex — fixes the single-handler overwrite bug for multi-monitor
    private var frameUpdateHandlers: [Int: (CVPixelBuffer) -> Void] = [:]
    // Weak ref to the active MonitorViewController for zoom toggle from toolbar
    weak var activeMonitorVC: MonitorViewController?
    weak var activeVNCMonitorVC: VNCMonitorViewController? {
        didSet {
            guard let activeVNCMonitorVC, let latestVNCFrame else { return }
            activeVNCMonitorVC.displayFrame(
                latestVNCFrame.image,
                remoteSize: latestVNCFrame.remoteSize,
                desktopSize: latestVNCFrame.desktopSize,
                imageCoversSelectedDisplay: latestVNCFrame.imageCoversSelectedDisplay
            )
        }
    }
    // Frames decoded before the MonitorView handler is registered
    private var pendingFrames: [Int: CVPixelBuffer] = [:]
    private var latestVNCFrame: (image: CGImage, remoteSize: CGSize, desktopSize: CGSize, imageCoversSelectedDisplay: Bool)?

    private var lastReportedLatency: Int = -1

    init() {
        frameDecoderStore.onFPSUpdate = { [weak self] fps in
            Task { @MainActor in self?.decodedFPS = fps }
        }
        frameDecoderStore.onPendingFrame = { [weak self] pixelBuffer, displayIndex in
            Task { @MainActor in self?.pendingFrames[displayIndex] = pixelBuffer }
        }
        frameDecoderStore.onRecoveryKeyframeNeeded = { [weak self] displayIndex in
            Task { @MainActor in
                self?.webSocketClient?.requestStream(displayIndex: displayIndex)
            }
        }
    }

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

    func connect(to host: DiscoveredHost, pairingCode: String? = nil) {
        connect(using: ConnectionRequest(
            mode: .airDesk,
            host: host,
            pairingCode: pairingCode,
            vncUsername: nil,
            vncPassword: nil
        ))
    }

    func connect(using request: ConnectionRequest) {
        switch request.mode {
        case .airDesk, .remoteAccess:
            connectAirDesk(using: request)
        case .vnc:
            connectVNC(using: request)
        }
    }

    private func connectAirDesk(using request: ConnectionRequest) {
        resetConnectionState(keepSelectedHost: true)
        selectedHost = request.host
        sessionMode = request.mode
        connectionState = .connecting
        errorMessage = nil
        let endpointDescription = request.remoteWebSocketURL?.absoluteString ?? "\(request.host.host):\(request.host.port)"
        AirDeskDiagnostics.shared.record("Connecting to \(request.host.name) at \(endpointDescription) using \(request.mode.title)")

        let client: WebSocketClient
        if let remoteURL = request.remoteWebSocketURL {
            client = WebSocketClient(url: remoteURL, pairingCode: request.pairingCode)
        } else {
            client = WebSocketClient(host: request.host.host, port: request.host.port, pairingCode: request.pairingCode)
        }
        let decoderStore = frameDecoderStore

        client.onMonitorsReceived = { [weak self] monitors in
            Task { @MainActor in
                AirDeskDiagnostics.shared.record("Received \(monitors.count) monitor(s)")
                let currentIndex = self?.activeMonitorIndex ?? 0
                self?.monitors = monitors
                if !monitors.contains(where: { $0.id == currentIndex }) {
                    self?.activeMonitorIndex = monitors.first?.id ?? 0
                }
                self?.pendingPairingRequest = nil
                self?.pairingChallenge = nil
                self?.connectionState = .connected
                self?.saveRemoteConnectionIfNeeded(request)
                self?.requestFreshFrames()
            }
        }

        // Video frames arrive on URLSession background thread — decode off main actor
        client.onVideoFrame = { data, displayIndex, isKeyframe, _, payloadOffset in
            decoderStore.decode(data, payloadOffset: payloadOffset, displayIndex: displayIndex, isKeyframe: isKeyframe)
        }

        client.onDisconnect = { [weak self] error in
            Task { @MainActor in
                AirDeskDiagnostics.shared.record("Disconnected: \(error?.localizedDescription ?? "clean")")
                self?.resetConnectionState(keepSelectedHost: false)
                self?.errorMessage = error?.localizedDescription
            }
        }

        client.onReconnectScheduled = { [weak self] _, _ in
            Task { @MainActor in
                AirDeskDiagnostics.shared.record("Reconnect scheduled")
                self?.connectionState = .reconnecting
            }
        }

        client.onClipboardChanged = { text in
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        }

        client.onLatencyUpdate = { [weak self] ms in
            Task { @MainActor in
                guard let self, ms != self.lastReportedLatency else { return }
                self.lastReportedLatency = ms
                self.latencyMs = ms
            }
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

        client.onPermissionStatusChanged = { [weak self] status in
            Task { @MainActor in
                self?.permissionStatus = status
            }
        }

        client.onPairingStatusChanged = { [weak self] status in
            Task { @MainActor in
                AirDeskDiagnostics.shared.record("Pairing status: \(status.message)")
                guard !status.paired else { return }
                if request.mode == .airDesk || request.mode == .remoteAccess {
                    self?.pendingPairingRequest = request
                    self?.pairingChallenge = PairingChallenge(
                        hostName: request.host.name,
                        mode: request.mode,
                        message: status.message
                    )
                    self?.errorMessage = nil
                    self?.resetConnectionState(keepSelectedHost: true)
                } else {
                    self?.pendingPairingRequest = nil
                    self?.pairingChallenge = nil
                    self?.errorMessage = status.message
                    self?.resetConnectionState(keepSelectedHost: false)
                    self?.startDiscovery()
                }
            }
        }

        client.connect()
        webSocketClient = client
    }

    func requestPairingCode(for request: ConnectionRequest) {
        AirDeskDiagnostics.shared.record("Opening pairing prompt for \(request.host.name)")
        pendingPairingRequest = request
        pairingChallenge = PairingChallenge(
            hostName: request.host.name,
            mode: request.mode,
            message: "Enter the six-digit code shown in the AirDesk Mac menu."
        )
        errorMessage = nil
    }

    func submitPairingCode(_ code: String) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6, let pendingPairingRequest else {
            errorMessage = "Enter the six-digit pairing code shown in the AirDesk Mac menu."
            return
        }
        let sanitizedCode = String(digits.prefix(6))
        AirDeskDiagnostics.shared.record("Submitting pairing code for \(pendingPairingRequest.host.name)")
        pairingChallenge = nil
        self.pendingPairingRequest = nil
        errorMessage = nil
        connect(using: pendingPairingRequest.withPairingCode(sanitizedCode))
    }

    func cancelPairingChallenge() {
        AirDeskDiagnostics.shared.record("Pairing prompt cancelled")
        pendingPairingRequest = nil
        pairingChallenge = nil
        resetConnectionState(keepSelectedHost: false)
        startDiscovery()
    }

    private func connectVNC(using request: ConnectionRequest) {
        let trimmedPassword = request.vncPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedPassword.isEmpty else {
            errorMessage = "Enter the VNC password before connecting."
            connectionState = .disconnected
            startDiscovery()
            return
        }

        resetConnectionState(keepSelectedHost: true)
        selectedHost = request.host
        sessionMode = .vnc
        connectionState = .connecting
        errorMessage = nil
        AirDeskDiagnostics.shared.record("Connecting to \(request.host.name) at \(request.host.host):\(request.host.port) using VNC")

        let controller = VNCSessionController(
            host: request.host.host,
            port: request.host.port,
            username: request.vncUsername,
            password: trimmedPassword
        )

        controller.onStateChanged = { [weak self, weak controller] status, error in
            Task { @MainActor in
                guard let self, let controller, self.vncSessionController === controller else { return }
                switch status {
                case .connecting:
                    self.connectionState = .connecting
                case .connected:
                    self.connectionState = .connected
                case .disconnecting:
                    break
                case .disconnected:
                    let userFacingMessage = controller.userFacingError(from: error)
                    let shouldDisplay = controller.shouldDisplay(error: error)
                    self.resetConnectionState(keepSelectedHost: false)
                    if shouldDisplay {
                        self.errorMessage = userFacingMessage
                    }
                    self.startDiscovery()
                }
            }
        }

        controller.onDesktopSizeChanged = { [weak self, weak controller] size in
            Task { @MainActor in
                guard let self, let controller, self.vncSessionController === controller else { return }
                self.vncFramebufferSize = size
            }
        }

        controller.onDisplayLayoutChanged = { [weak self, weak controller] size, displays in
            Task { @MainActor in
                guard let self, let controller, self.vncSessionController === controller else { return }
                self.vncFramebufferSize = size
                self.vncDisplays = displays

                if let activeID = self.activeVNCDisplayID,
                   displays.contains(where: { $0.id == activeID }) {
                    controller.setActiveDisplay(displays.first(where: { $0.id == activeID }))
                    return
                }

                let firstDisplay = displays.first
                self.activeVNCDisplayID = firstDisplay?.id
                controller.setActiveDisplay(firstDisplay)
            }
        }

        controller.onFramebufferUpdated = { [weak self, weak controller] image, imageSize, imageCoversSelectedDisplay in
            Task { @MainActor in
                guard let self, let controller, self.vncSessionController === controller else { return }
                if self.vncFramebufferImageSize != imageSize {
                    self.vncFramebufferImageSize = imageSize
                }
                if self.vncFramebufferImageCoversSelectedDisplay != imageCoversSelectedDisplay {
                    self.vncFramebufferImageCoversSelectedDisplay = imageCoversSelectedDisplay
                }
                if !self.vncHasFramebuffer {
                    self.vncHasFramebuffer = true
                }
                self.latestVNCFrame = (
                    image: image,
                    remoteSize: imageSize,
                    desktopSize: self.vncFramebufferSize,
                    imageCoversSelectedDisplay: imageCoversSelectedDisplay
                )
                self.activeVNCMonitorVC?.displayFrame(
                    image,
                    remoteSize: imageSize,
                    desktopSize: self.vncFramebufferSize,
                    imageCoversSelectedDisplay: imageCoversSelectedDisplay
                )
                if self.connectionState != .connected {
                    self.connectionState = .connected
                }
            }
        }

        controller.connect()
        vncSessionController = controller
    }

    func disconnect() {
        AirDeskDiagnostics.shared.record("Disconnect requested")
        resetConnectionState(keepSelectedHost: false)
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

    private func requestFreshFrames() {
        guard connectionState == .connected else { return }
        if monitors.contains(where: { $0.id == activeMonitorIndex }) {
            webSocketClient?.requestStream(displayIndex: activeMonitorIndex)
        }
    }

    private func saveRemoteConnectionIfNeeded(_ request: ConnectionRequest) {
        guard request.mode == .remoteAccess,
              let remoteURL = request.remoteWebSocketURL else { return }
        remoteConnectionStore.save(
            urlString: remoteURL.absoluteString,
            pairingCode: request.pairingCode,
            name: request.host.name
        )
    }

    private func resetConnectionState(keepSelectedHost: Bool) {
        let existingWebSocketClient = webSocketClient
        webSocketClient = nil
        existingWebSocketClient?.disconnect()
        let existingVNCSessionController = vncSessionController
        vncSessionController = nil
        existingVNCSessionController?.disconnect()
        connectionState = .disconnected
        sessionMode = nil
        monitors = []
        activeMonitorIndex = 0
        if !keepSelectedHost {
            selectedHost = nil
        }
        latencyMs = 0
        decodedFPS = 0
        isHostLocked = false
        hostStatusMessage = nil
        permissionStatus = .controlReady
        vncFramebufferImage = nil
        vncFramebufferSize = .zero
        vncFramebufferImageSize = .zero
        vncFramebufferImageCoversSelectedDisplay = false
        vncHasFramebuffer = false
        vncFrameRevision = 0
        vncDisplays = []
        activeVNCDisplayID = nil
        activeVNCMonitorVC = nil
        latestVNCFrame = nil
        lastReportedLatency = -1
        FrameRelay.shared.removeAll()
        frameUpdateHandlers.removeAll()
        pendingFrames.removeAll()
        frameDecoderStore.reset()
    }

    func selectVNCDisplay(_ id: UInt32) {
        guard let display = vncDisplays.first(where: { $0.id == id }) else { return }
        activeVNCDisplayID = id
        vncFramebufferImage = nil
        vncFramebufferImageSize = .zero
        vncFramebufferImageCoversSelectedDisplay = false
        vncHasFramebuffer = false
        latestVNCFrame = nil
        vncSessionController?.setActiveDisplay(display)
    }
}
