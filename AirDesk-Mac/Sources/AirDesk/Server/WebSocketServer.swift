import Foundation
import Network

class WebSocketServer: NSObject, H264EncoderDelegate {

    // All access to `connections`, `latestKeyframes`, and `pendingSendCount` must happen on serverQueue
    private var connections: [NWConnection] = []
    private var latestKeyframes: [Int: Data] = [:]
    private var pendingSendCount: [ObjectIdentifier: Int] = [:]
    private var awaitingKeyframe: Set<ObjectIdentifier> = []
    private var listener: NWListener?
    private let port: UInt16
    let serverQueue = DispatchQueue(label: "airdesk.server")
    private var lastRefreshTime: CFAbsoluteTime = 0
    private var lockObserver: Any?

    weak var inputDelegate: InputInjector?
    weak var encoder: H264Encoder?
    var clientChangeHandler: ((Int) -> Void)?
    var monitorInfoProvider: (() -> [MonitorInfo])?
    var clipboardDelegate: ClipboardManager?

    init(port: UInt16) {
        self.port = port
        super.init()
    }

    func start() {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.serverQueue.async { self?.handleNewConnection(connection) }
        }
        listener.start(queue: serverQueue)
        print("WebSocket server started on port \(port)")
        setupLockDetection()
    }

    func stop() {
        serverQueue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
            self.pendingSendCount.removeAll()
            self.awaitingKeyframe.removeAll()
            if let observer = self.lockObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            self.lockObserver = nil
        }
    }

    // MARK: - Broadcast helpers (safe to call from any queue)

    func broadcastText(_ text: String) {
        serverQueue.async { [weak self] in
            self?.connections.forEach { self?.sendText(text, to: $0) }
        }
    }

    // MARK: - Lock Detection

    private func setupLockDetection() {
        Task { @MainActor in
            _ = LockStatusMonitor.shared
        }
        lockObserver = NotificationCenter.default.addObserver(
            forName: .screenLockStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isLocked = notification.object as? Bool else { return }
            self?.broadcastLockStatus(isLocked)
        }
    }

    private func broadcastLockStatus(_ isLocked: Bool) {
        let statusMsg = LockStatusMessage(
            isLocked: isLocked,
            message: isLocked ? "Screen is locked — viewing only" : "Control ready"
        )
        guard let data = try? JSONEncoder().encode(statusMsg),
              let text = String(data: data, encoding: .utf8) else { return }
        broadcastText(text)
        guard !isLocked else { return }
        encoder?.forceKeyframeOnNextFrame()
        refreshAllDisplays()
    }

    func handleMonitorConfigurationChange(_ monitors: [MonitorInfo]) {
        serverQueue.async { [weak self] in
            guard let self else { return }
            self.latestKeyframes = self.latestKeyframes.filter { $0.key < monitors.count }
            self.awaitingKeyframe.removeAll()
            let msg = ScreenInfoMessage(monitors: monitors)
            guard let data = try? JSONEncoder().encode(msg),
                  let text = String(data: data, encoding: .utf8) else { return }
            self.connections.forEach { self.sendText(text, to: $0) }
            self.encoder?.forceKeyframeOnNextFrame()
            self.refreshAllDisplays()
        }
    }

    // MARK: - Private — must only be called on serverQueue

    private func handleNewConnection(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        print("New WebSocket connection from \(connection.endpoint)")
        connections.append(connection)
        let count = connections.count
        DispatchQueue.main.async { self.clientChangeHandler?(count) }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            // Dispatch onto serverQueue to safely mutate connections
            self.serverQueue.async {
                switch state {
                case .failed, .cancelled:
                    let id = ObjectIdentifier(connection)
                    self.pendingSendCount.removeValue(forKey: id)
                    self.awaitingKeyframe.remove(id)
                    self.connections.removeAll { $0 === connection }
                    let count = self.connections.count
                    DispatchQueue.main.async { self.clientChangeHandler?(count) }
                default:
                    break
                }
            }
        }

        connection.start(queue: serverQueue)
        receive(from: connection)
        encoder?.forceKeyframeOnNextFrame()
    }

    private func receive(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty,
               let context,
               let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .text:
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleTextMessage(text, from: connection)
                    }
                default:
                    break
                }
            }
            if error == nil { self.receive(from: connection) }
        }
    }

    private func handleTextMessage(_ text: String, from connection: NWConnection) {
        print("Received text: \(text.prefix(200))")
        let message = parseIncomingMessage(text)
        switch message {
        case .connect:
            print("Sending screen info")
            sendScreenInfo(to: connection)
            sendCurrentLockStatus(to: connection)
        case .mouse(let msg):
            inputDelegate?.handleMouseMessage(msg)
            // Only capture refresh frames for discrete actions (click, doubleClick, rightClick).
            // Continuous actions (scroll, drag, move) generate many events per second —
            // ScreenCaptureKit already captures those screen changes naturally.
            // Firing CGDisplayCreateImage captures during scroll causes visible flashing
            // because CGDisplayCreateImage produces frames that look different from SCK.
            switch msg.action {
            case "click", "doubleClick", "rightClick", "dragEnd":
                scheduleRefreshCapture(displayIndex: msg.displayIndex)
            default:
                break
            }
        case .keyboard(let msg):
            inputDelegate?.handleKeyboardMessage(msg)
            scheduleRefreshCapture(displayIndex: 0)
        case .clipboard(let msg):
            clipboardDelegate?.writeToClipboard(msg.content)
        case .systemAction(let msg):
            DispatchQueue.main.async { self.inputDelegate?.handleSystemAction(msg) }
        case .requestStream(let msg):
            print("Client requested stream for display \(msg.displayIndex) at \(msg.fps)fps quality=\(msg.quality)")
            encoder?.forceKeyframeOnNextFrame()
            // Send cached keyframe immediately so client doesn't wait for next screen change
            if let cached = latestKeyframes[msg.displayIndex] {
                sendBinary(cached, to: connection)
            }
            // Also capture a fresh frame directly — works even when screen is static
            encoder?.captureAndEncodeImmediate(displayIndex: msg.displayIndex)
        case .unknown:
            break
        }
    }

    private func sendScreenInfo(to connection: NWConnection) {
        let monitors = monitorInfoProvider?() ?? []
        let msg = ScreenInfoMessage(monitors: monitors)
        guard let data = try? JSONEncoder().encode(msg),
              let text = String(data: data, encoding: .utf8) else { return }
        sendText(text, to: connection)
    }

    private func sendText(_ text: String, to connection: NWConnection) {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    private func sendBinary(_ data: Data, to connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        pendingSendCount[id, default: 0] += 1
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        connection.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed({ [weak self] _ in
            self?.serverQueue.async {
                let count = self?.pendingSendCount[id, default: 1] ?? 1
                self?.pendingSendCount[id] = max(0, count - 1)
            }
        }))
    }

    private func sendCurrentLockStatus(to connection: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = LockStatusMonitor.shared.isLocked
            self.serverQueue.async {
                let msg = LockStatusMessage(
                    isLocked: status,
                    message: status ? "Screen is locked — viewing only" : "Control ready"
                )
                guard let data = try? JSONEncoder().encode(msg),
                      let text = String(data: data, encoding: .utf8) else { return }
                self.sendText(text, to: connection)
            }
        }
    }

    private func refreshAllDisplays() {
        let displayCount = monitorInfoProvider?().count ?? 0
        guard displayCount > 0 else { return }
        for index in 0..<displayCount {
            for delay in [0.02, 0.15, 0.4] {
                serverQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.encoder?.captureAndEncodeImmediate(displayIndex: index)
                }
            }
        }
    }

    /// Triggers CGDisplayCreateImage captures after input events to ensure
    /// the iOS display refreshes even if ScreenCaptureKit misses the change.
    /// Fires a short burst of captures to catch UI animations (e.g. new tab
    /// opening, menu appearing).
    private func scheduleRefreshCapture(displayIndex: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRefreshTime > 0.033 else { return }
        lastRefreshTime = now
        // Burst: capture at 10ms, 100ms, 250ms, and 500ms after the event
        // to catch both instant changes and short animations.
        for delay in [0.01, 0.1, 0.25, 0.5] {
            serverQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.encoder?.captureAndEncodeImmediate(displayIndex: displayIndex)
            }
        }
    }

    // MARK: - H264EncoderDelegate

    private var broadcastLogCounter = 0

    func didEncodeFrame(_ data: Data, isKeyframe: Bool, displayIndex: Int, timestamp: Double) {
        let tsMs = UInt32(timestamp * 1000) & 0xFFFFFFFF
        let header = VideoFrameHeader(displayIndex: displayIndex, timestampMs: tsMs, isKeyframe: isKeyframe)
        let frame = header.buildFrame(with: data)
        serverQueue.async { [weak self] in
            guard let self else { return }
            var shouldForceKeyframe = false
            self.broadcastLogCounter += 1
            if self.broadcastLogCounter <= 3 || self.broadcastLogCounter % 300 == 0 {
                print("[AirDesk] Broadcasting frame #\(self.broadcastLogCounter) (\(frame.count) bytes) to \(self.connections.count) clients")
            }
            if isKeyframe {
                self.latestKeyframes[displayIndex] = frame
            }
            for conn in self.connections {
                let id = ObjectIdentifier(conn)
                if self.awaitingKeyframe.contains(id) {
                    if isKeyframe {
                        self.awaitingKeyframe.remove(id)
                        self.sendBinary(frame, to: conn)
                    }
                    continue
                }

                let pending = self.pendingSendCount[id, default: 0]
                if pending < 3 || isKeyframe {
                    self.sendBinary(frame, to: conn)
                } else {
                    self.awaitingKeyframe.insert(id)
                    shouldForceKeyframe = true
                }
            }
            if shouldForceKeyframe {
                self.encoder?.forceKeyframeOnNextFrame()
            }
        }
    }
}
