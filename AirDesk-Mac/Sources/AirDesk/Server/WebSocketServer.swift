import Foundation
import Network
import AirDeskProtocol

final class WebSocketServer: NSObject, H264EncoderDelegate, @unchecked Sendable {

    private struct QueuedBinaryFrame {
        let data: Data
        let displayIndex: Int
        let isKeyframe: Bool
    }

    private struct ConnectionDisplayKey: Hashable {
        let connectionID: ObjectIdentifier
        let displayIndex: Int
    }

    // All access to connection/video state must happen on serverQueue.
    private var connections: [NWConnection] = []
    private var latestKeyframes: [Int: Data] = [:]
    private var activeBinarySends: Set<ObjectIdentifier> = []
    private var queuedBinaryFrames: [ObjectIdentifier: [Int: QueuedBinaryFrame]] = [:]
    private var queuedDisplayOrder: [ObjectIdentifier: [Int]] = [:]
    private var awaitingKeyframes: Set<ConnectionDisplayKey> = []
    private var backpressureRecoveryLogCounter = 0
    private var authorizedConnections: Set<ObjectIdentifier> = []
    private var pendingDisplayInputRefreshes: [Int: DispatchWorkItem] = [:]
    private var lastFrameBroadcastTime: [Int: CFAbsoluteTime] = [:]
    private var lastDisplayInputKeyframeTime: [Int: CFAbsoluteTime] = [:]
    private var pendingKeyboardRefresh: DispatchWorkItem?
    private var lastKeyboardKeyframeTime: CFAbsoluteTime = 0
    private var listener: NWListener?
    private let port: UInt16
    let serverQueue = DispatchQueue(label: "airdesk.server")
    private let displayInputFallbackDelay: TimeInterval = 0.075
    private let displayInputKeyframeInterval: CFAbsoluteTime = 0.75
    private let keyboardInputKeyframeInterval: CFAbsoluteTime = 0.15
    private var lockObserver: Any?
    private var permissionStatusTimer: DispatchSourceTimer?

    weak var inputDelegate: InputInjector?
    weak var encoder: H264Encoder?
    var clientChangeHandler: ((Int) -> Void)?
    var monitorInfoProvider: (() -> [MonitorInfo])?
    var clipboardDelegate: ClipboardManager?
    var pairingManager: PairingManager?

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
        AirDeskDiagnostics.shared.record("WebSocket server started on port \(port)")
        setupLockDetection()
        startPermissionStatusTimer()
    }

    func stop() {
        serverQueue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
            self.activeBinarySends.removeAll()
            self.queuedBinaryFrames.removeAll()
            self.queuedDisplayOrder.removeAll()
            self.awaitingKeyframes.removeAll()
            self.backpressureRecoveryLogCounter = 0
            self.authorizedConnections.removeAll()
            self.pendingDisplayInputRefreshes.values.forEach { $0.cancel() }
            self.pendingDisplayInputRefreshes.removeAll()
            self.lastFrameBroadcastTime.removeAll()
            self.lastDisplayInputKeyframeTime.removeAll()
            self.pendingKeyboardRefresh?.cancel()
            self.pendingKeyboardRefresh = nil
            self.lastKeyboardKeyframeTime = 0
            if let observer = self.lockObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            self.lockObserver = nil
            self.permissionStatusTimer?.cancel()
            self.permissionStatusTimer = nil
        }
    }

    // MARK: - Broadcast helpers (safe to call from any queue)

    func broadcastText(_ text: String) {
        serverQueue.async { [weak self] in
            guard let self else { return }
            self.authorizedConnectionList().forEach { self.sendText(text, to: $0) }
        }
    }

    func broadcastPermissionStatus() {
        serverQueue.async { [weak self] in
            self?.broadcastPermissionStatusOnQueue()
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
        serverQueue.async { [weak self] in
            guard let self else { return }
            self.latestKeyframes.removeAll()
            self.queuedBinaryFrames.removeAll()
            self.queuedDisplayOrder.removeAll()
            self.awaitingKeyframes.removeAll()
            self.refreshActiveDisplaysOnQueue()
            self.scheduleActiveDisplayRefreshOnQueue(after: 0.45)
            self.scheduleActiveDisplayRefreshOnQueue(after: 1.0)
        }
    }

    func handleMonitorConfigurationChange(_ monitors: [MonitorInfo]) {
        serverQueue.async { [weak self] in
            guard let self else { return }
            self.latestKeyframes.removeAll()
            self.queuedBinaryFrames.removeAll()
            self.queuedDisplayOrder.removeAll()
            self.awaitingKeyframes.removeAll()
            let msg = ScreenInfoMessage(monitors: monitors)
            guard let data = try? JSONEncoder().encode(msg),
                  let text = String(data: data, encoding: .utf8) else { return }
            self.authorizedConnectionList().forEach { self.sendText(text, to: $0) }
            self.refreshDisplaysOnQueue(monitors.map(\.id))
        }
    }

    private func refreshActiveDisplaysOnQueue() {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        let displayIndexes = (monitorInfoProvider?() ?? []).map(\.id)
        refreshDisplaysOnQueue(displayIndexes.isEmpty ? [0] : displayIndexes)
    }

    private func refreshDisplaysOnQueue(_ displayIndexes: [Int]) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        for displayIndex in displayIndexes {
            encoder?.captureAndEncodeImmediate(displayIndex: displayIndex, forceKeyframe: true)
        }
    }

    private func scheduleActiveDisplayRefreshOnQueue(after delay: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        serverQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refreshActiveDisplaysOnQueue()
        }
    }

    // MARK: - Private — must only be called on serverQueue

    private func handleNewConnection(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        print("New WebSocket connection from \(connection.endpoint)")
        AirDeskDiagnostics.shared.record("New connection from \(connection.endpoint)")
        connections.append(connection)
        notifyAuthorizedClientCount()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            // Dispatch onto serverQueue to safely mutate connections
            self.serverQueue.async {
                switch state {
                case .failed, .cancelled:
                    let id = ObjectIdentifier(connection)
                    self.clearVideoBacklog(for: id)
                    self.authorizedConnections.remove(id)
                    self.connections.removeAll { $0 === connection }
                    self.notifyAuthorizedClientCount()
                default:
                    break
                }
            }
        }

        connection.start(queue: serverQueue)
        receive(from: connection)
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
        let message = parseIncomingMessage(text)
        switch message {
        case .connect(let msg):
            guard authorizeConnection(connection, message: msg) else { return }
            print("Sending screen info")
            sendScreenInfo(to: connection)
            sendCurrentLockStatus(to: connection)
            sendPermissionStatus(to: connection)
        case .mouse(let msg):
            guard isAuthorized(connection) else {
                sendPairingRequired(to: connection)
                return
            }
            guard PermissionChecker.hasAccessibilityPermission() else {
                sendPermissionStatus(to: connection)
                return
            }
            inputDelegate?.handleMouseMessage(msg)
            switch msg.action {
            case "click", "doubleClick", "rightClick", "dragEnd":
                encoder?.forceKeyframeOnNextFrame(displayIndex: msg.displayIndex)
            case "scroll":
                scheduleDisplayVisualRefreshAfterInput(displayIndex: msg.displayIndex)
            default:
                break
            }
        case .keyboard(let msg):
            guard isAuthorized(connection) else {
                sendPairingRequired(to: connection)
                return
            }
            guard PermissionChecker.hasAccessibilityPermission() else {
                sendPermissionStatus(to: connection)
                return
            }
            inputDelegate?.handleKeyboardMessage(msg)
            if msg.action == "down" {
                scheduleKeyboardVisualRefreshAfterInput()
            }
            if msg.action == "up", msg.keyCode == 36 {
                scheduleActiveDisplayRefreshOnQueue(after: 0.25)
                scheduleActiveDisplayRefreshOnQueue(after: 0.8)
            }
        case .clipboard(let msg):
            guard isAuthorized(connection) else {
                sendPairingRequired(to: connection)
                return
            }
            clipboardDelegate?.writeToClipboard(msg.content)
        case .systemAction(let msg):
            guard isAuthorized(connection) else {
                sendPairingRequired(to: connection)
                return
            }
            DispatchQueue.main.async { self.inputDelegate?.handleSystemAction(msg) }
        case .requestStream(let msg):
            guard isAuthorized(connection) else {
                sendPairingRequired(to: connection)
                return
            }
            print("Client requested stream for display \(msg.displayIndex) at \(msg.fps)fps quality=\(msg.quality)")
            // Send cached keyframe immediately so client doesn't wait for next screen change
            if let cached = latestKeyframes[msg.displayIndex] {
                enqueueBinaryFrame(
                    QueuedBinaryFrame(data: cached, displayIndex: msg.displayIndex, isKeyframe: true),
                    to: connection
                )
            }
            encoder?.captureAndEncodeImmediate(displayIndex: msg.displayIndex, forceKeyframe: true)
        case .unknown:
            if isConnectLikeMessage(text) {
                let status = PairingStatusMessage(
                    paired: false,
                    message: "This iOS AirDesk app is not compatible with the current Mac app. Update the iOS app, then enter the pairing code shown in the AirDesk Mac menu."
                )
                AirDeskDiagnostics.shared.record("Rejected malformed native connect request")
                sendPairingStatus(status, to: connection)
            }
            break
        }
    }

    private func scheduleDisplayVisualRefreshAfterInput(displayIndex: Int) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        let now = CFAbsoluteTimeGetCurrent()
        scheduleFallbackDisplayRefresh(displayIndex: displayIndex, inputTime: now)
        scheduleDisplayInputRecoveryKeyframeIfNeeded(displayIndex: displayIndex, now: now)
    }

    private func scheduleFallbackDisplayRefresh(displayIndex: Int, inputTime: CFAbsoluteTime) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        pendingDisplayInputRefreshes[displayIndex]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDisplayInputRefreshes[displayIndex] = nil
            guard !self.authorizedConnectionList().isEmpty else { return }
            if (self.lastFrameBroadcastTime[displayIndex] ?? 0) >= inputTime {
                return
            }
            self.encoder?.captureAndEncodeImmediate(displayIndex: displayIndex, forceKeyframe: false)
        }
        pendingDisplayInputRefreshes[displayIndex] = workItem
        serverQueue.asyncAfter(deadline: .now() + displayInputFallbackDelay, execute: workItem)
    }

    private func scheduleDisplayInputRecoveryKeyframeIfNeeded(displayIndex: Int, now: CFAbsoluteTime) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        let elapsed = now - (lastDisplayInputKeyframeTime[displayIndex] ?? 0)
        guard elapsed >= displayInputKeyframeInterval else { return }
        lastDisplayInputKeyframeTime[displayIndex] = now
        encoder?.forceKeyframeOnNextFrame(displayIndex: displayIndex)
    }

    private func scheduleKeyboardVisualRefreshAfterInput() {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastKeyboardKeyframeTime

        if elapsed >= keyboardInputKeyframeInterval {
            pendingKeyboardRefresh?.cancel()
            pendingKeyboardRefresh = nil
            lastKeyboardKeyframeTime = now
            encoder?.forceKeyframeOnNextFrame()
            return
        }

        guard pendingKeyboardRefresh == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingKeyboardRefresh = nil
            guard !self.authorizedConnectionList().isEmpty else { return }
            self.lastKeyboardKeyframeTime = CFAbsoluteTimeGetCurrent()
            self.encoder?.forceKeyframeOnNextFrame()
        }
        pendingKeyboardRefresh = workItem
        serverQueue.asyncAfter(deadline: .now() + (keyboardInputKeyframeInterval - elapsed), execute: workItem)
    }

    private func isConnectLikeMessage(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return false }
        return type == "connect"
    }

    private func authorizeConnection(_ connection: NWConnection, message: ConnectMessage) -> Bool {
        let status = pairingManager?.authorize(message)
            ?? PairingStatusMessage(paired: true, message: "Paired")
        sendPairingStatus(status, to: connection)
        guard status.paired else { return false }
        authorizedConnections.insert(ObjectIdentifier(connection))
        notifyAuthorizedClientCount()
        return true
    }

    private func isAuthorized(_ connection: NWConnection) -> Bool {
        authorizedConnections.contains(ObjectIdentifier(connection))
    }

    private func authorizedConnectionList() -> [NWConnection] {
        connections.filter { authorizedConnections.contains(ObjectIdentifier($0)) }
    }

    private func notifyAuthorizedClientCount() {
        let count = authorizedConnectionList().count
        DispatchQueue.main.async { self.clientChangeHandler?(count) }
    }

    private func sendPairingRequired(to connection: NWConnection) {
        sendPairingStatus(
            PairingStatusMessage(paired: false, message: "Pairing required. Enter the code shown in the AirDesk Mac menu."),
            to: connection
        )
    }

    private func sendPairingStatus(_ status: PairingStatusMessage, to connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(status),
              let text = String(data: data, encoding: .utf8) else { return }
        sendText(text, to: connection)
    }

    private func sendScreenInfo(to connection: NWConnection) {
        guard isAuthorized(connection) else { return }
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

    private func startPermissionStatusTimer() {
        serverQueue.async { [weak self] in
            guard let self, self.permissionStatusTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.serverQueue)
            timer.schedule(deadline: .now() + 1.0, repeating: .seconds(3))
            timer.setEventHandler { [weak self] in
                self?.broadcastPermissionStatusOnQueue()
            }
            self.permissionStatusTimer = timer
            timer.resume()
        }
    }

    private func broadcastPermissionStatusOnQueue() {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        let targets = authorizedConnectionList()
        guard !targets.isEmpty else { return }
        guard let text = permissionStatusText() else { return }
        targets.forEach { sendText(text, to: $0) }
    }

    private func sendPermissionStatus(to connection: NWConnection) {
        guard isAuthorized(connection) else { return }
        guard let text = permissionStatusText() else { return }
        sendText(text, to: connection)
    }

    private func permissionStatusText() -> String? {
        let msg = PermissionChecker.currentStatusMessage()
        guard let data = try? JSONEncoder().encode(msg) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func enqueueBinaryFrame(_ frame: QueuedBinaryFrame, to connection: NWConnection) -> Bool {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        guard isAuthorized(connection) else { return false }
        let id = ObjectIdentifier(connection)

        if activeBinarySends.contains(id) {
            return queueLatestFrame(frame, for: id)
        }

        sendBinaryFrame(frame, to: connection)
        return false
    }

    private func queueLatestFrame(_ frame: QueuedBinaryFrame, for connectionID: ObjectIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        let key = ConnectionDisplayKey(connectionID: connectionID, displayIndex: frame.displayIndex)
        var queued = queuedBinaryFrames[connectionID, default: [:]]

        if let existing = queued[frame.displayIndex] {
            if frame.isKeyframe {
                queued[frame.displayIndex] = frame
                queuedBinaryFrames[connectionID] = queued
                awaitingKeyframes.remove(key)
                addQueuedDisplay(frame.displayIndex, for: connectionID)
                return false
            }

            if existing.isKeyframe {
                return false
            }

            queued.removeValue(forKey: frame.displayIndex)
            if queued.isEmpty {
                queuedBinaryFrames.removeValue(forKey: connectionID)
            } else {
                queuedBinaryFrames[connectionID] = queued
            }
            removeQueuedDisplay(frame.displayIndex, for: connectionID)
            return markAwaitingRecoveryKeyframe(connectionID: connectionID, displayIndex: frame.displayIndex)
        }

        queued[frame.displayIndex] = frame
        queuedBinaryFrames[connectionID] = queued
        addQueuedDisplay(frame.displayIndex, for: connectionID)
        return false
    }

    private func sendBinaryFrame(_ frame: QueuedBinaryFrame, to connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        guard isAuthorized(connection) else { return }
        let id = ObjectIdentifier(connection)
        activeBinarySends.insert(id)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        connection.send(content: frame.data, contentContext: ctx, isComplete: true, completion: .contentProcessed({ [weak self] error in
            self?.serverQueue.async { [weak self] in
                guard let self else { return }
                self.activeBinarySends.remove(id)
                if let error {
                    AirDeskDiagnostics.shared.record("Video send failed: \(error.localizedDescription)")
                    self.clearVideoBacklog(for: id)
                    return
                }
                guard self.isAuthorized(connection) else {
                    self.clearVideoBacklog(for: id)
                    return
                }
                guard let next = self.dequeueNextFrame(for: id) else { return }
                let nextKey = ConnectionDisplayKey(connectionID: id, displayIndex: next.displayIndex)
                if self.awaitingKeyframes.contains(nextKey), !next.isKeyframe {
                    return
                }
                if next.isKeyframe {
                    self.awaitingKeyframes.remove(nextKey)
                }
                self.sendBinaryFrame(next, to: connection)
            }
        }))
    }

    private func dequeueNextFrame(for connectionID: ObjectIdentifier) -> QueuedBinaryFrame? {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        guard var queued = queuedBinaryFrames[connectionID], !queued.isEmpty else {
            queuedDisplayOrder.removeValue(forKey: connectionID)
            return nil
        }

        let order = queuedDisplayOrder[connectionID] ?? Array(queued.keys).sorted()
        let displayIndex = order.first(where: { queued[$0]?.isKeyframe == true })
            ?? order.first(where: { queued[$0] != nil })
            ?? queued.keys.sorted().first
        guard let displayIndex, let frame = queued.removeValue(forKey: displayIndex) else { return nil }

        if queued.isEmpty {
            queuedBinaryFrames.removeValue(forKey: connectionID)
            queuedDisplayOrder.removeValue(forKey: connectionID)
        } else {
            queuedBinaryFrames[connectionID] = queued
            removeQueuedDisplay(displayIndex, for: connectionID)
        }
        return frame
    }

    private func addQueuedDisplay(_ displayIndex: Int, for connectionID: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        var order = queuedDisplayOrder[connectionID, default: []]
        if !order.contains(displayIndex) {
            order.append(displayIndex)
            queuedDisplayOrder[connectionID] = order
        }
    }

    private func removeQueuedDisplay(_ displayIndex: Int, for connectionID: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        guard var order = queuedDisplayOrder[connectionID] else { return }
        order.removeAll { $0 == displayIndex }
        if order.isEmpty {
            queuedDisplayOrder.removeValue(forKey: connectionID)
        } else {
            queuedDisplayOrder[connectionID] = order
        }
    }

    private func markAwaitingRecoveryKeyframe(connectionID: ObjectIdentifier, displayIndex: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        let key = ConnectionDisplayKey(connectionID: connectionID, displayIndex: displayIndex)
        let inserted = awaitingKeyframes.insert(key).inserted
        guard inserted else { return false }

        backpressureRecoveryLogCounter += 1
        if backpressureRecoveryLogCounter <= 5 || backpressureRecoveryLogCounter % 60 == 0 {
            AirDeskDiagnostics.shared.record("Video backpressure on display \(displayIndex); requesting recovery keyframe")
        }
        return true
    }

    private func clearVideoBacklog(for connectionID: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        activeBinarySends.remove(connectionID)
        queuedBinaryFrames.removeValue(forKey: connectionID)
        queuedDisplayOrder.removeValue(forKey: connectionID)
        awaitingKeyframes = awaitingKeyframes.filter { $0.connectionID != connectionID }
    }

    private func sendCurrentLockStatus(to connection: NWConnection) {
        let queue = serverQueue
        Task { @MainActor in
            let status = LockStatusMonitor.shared.isLocked
            let msg = LockStatusMessage(
                isLocked: status,
                message: status ? "Screen is locked — viewing only" : "Control ready"
            )
            guard let data = try? JSONEncoder().encode(msg),
                  let text = String(data: data, encoding: .utf8) else { return }
            queue.async { [weak self] in
                guard let self else { return }
                guard self.isAuthorized(connection) else { return }
                self.sendText(text, to: connection)
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
            var displaysNeedingKeyframe = Set<Int>()
            self.broadcastLogCounter += 1
            let targets = self.authorizedConnectionList()
            if self.broadcastLogCounter <= 3 || self.broadcastLogCounter % 300 == 0 {
                print("[AirDesk] Broadcasting frame #\(self.broadcastLogCounter) (\(frame.count) bytes) to \(targets.count) paired clients")
            }
            if isKeyframe {
                self.latestKeyframes[displayIndex] = frame
            }
            self.lastFrameBroadcastTime[displayIndex] = CFAbsoluteTimeGetCurrent()
            for conn in targets {
                let id = ObjectIdentifier(conn)
                let key = ConnectionDisplayKey(connectionID: id, displayIndex: displayIndex)
                if self.awaitingKeyframes.contains(key) {
                    if isKeyframe {
                        self.awaitingKeyframes.remove(key)
                        self.enqueueBinaryFrame(
                            QueuedBinaryFrame(data: frame, displayIndex: displayIndex, isKeyframe: true),
                            to: conn
                        )
                    }
                    continue
                }

                let needsKeyframe = self.enqueueBinaryFrame(
                    QueuedBinaryFrame(data: frame, displayIndex: displayIndex, isKeyframe: isKeyframe),
                    to: conn
                )
                if needsKeyframe {
                    displaysNeedingKeyframe.insert(displayIndex)
                }
            }
            for displayIndex in displaysNeedingKeyframe {
                self.encoder?.forceKeyframeOnNextFrame(displayIndex: displayIndex)
            }
        }
    }
}
