import Foundation
import Network

class WebSocketServer: NSObject, H264EncoderDelegate {

    // All access to `connections` and `latestKeyframes` must happen on serverQueue
    private var connections: [NWConnection] = []
    private var latestKeyframes: [Int: Data] = [:]
    private var listener: NWListener?
    private let port: UInt16
    let serverQueue = DispatchQueue(label: "airdesk.server")
    private var lastRefreshTime: CFAbsoluteTime = 0

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
    }

    func stop() {
        serverQueue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    // MARK: - Broadcast helpers (safe to call from any queue)

    func broadcastText(_ text: String) {
        serverQueue.async { [weak self] in
            self?.connections.forEach { self?.sendText(text, to: $0) }
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
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        connection.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
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
            self.broadcastLogCounter += 1
            if self.broadcastLogCounter <= 3 || self.broadcastLogCounter % 300 == 0 {
                print("[AirDesk] Broadcasting frame #\(self.broadcastLogCounter) (\(frame.count) bytes) to \(self.connections.count) clients")
            }
            if isKeyframe {
                self.latestKeyframes[displayIndex] = frame
            }
            self.connections.forEach { self.sendBinary(frame, to: $0) }
        }
    }
}
