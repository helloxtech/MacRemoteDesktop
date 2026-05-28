import Foundation
import Network
import AirDeskProtocol

final class WebSocketServer: NSObject, H264EncoderDelegate, @unchecked Sendable {

    private struct ConnectionDisplayKey: Hashable {
        let connectionID: ObjectIdentifier
        let displayIndex: Int
    }

    // All access to connection/video state must happen on serverQueue.
    private var connections: [NWConnection] = []
    private var latestKeyframes: [Int: Data] = [:]
    private var pendingSendCount: [ObjectIdentifier: Int] = [:]
    private var awaitingKeyframes: Set<ConnectionDisplayKey> = []
    private var requestedRecoveryKeyframes: Set<ConnectionDisplayKey> = []
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
    private let minimumRemoteAccessClientVersion = "1.2.5"
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
            self.pendingSendCount.removeAll()
            self.awaitingKeyframes.removeAll()
            self.requestedRecoveryKeyframes.removeAll()
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
            self.awaitingKeyframes.removeAll()
            self.requestedRecoveryKeyframes.removeAll()
            self.refreshActiveDisplaysOnQueue()
            self.scheduleActiveDisplayRefreshOnQueue(after: 0.45)
            self.scheduleActiveDisplayRefreshOnQueue(after: 1.0)
        }
    }

    func handleMonitorConfigurationChange(_ monitors: [MonitorInfo]) {
        serverQueue.async { [weak self] in
            guard let self else { return }
            self.latestKeyframes.removeAll()
            self.awaitingKeyframes.removeAll()
            self.requestedRecoveryKeyframes.removeAll()
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
                    self.pendingSendCount.removeValue(forKey: id)
                    self.clearRecoveryState(for: id)
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
                sendBinary(cached, to: connection)
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
        if requiresMinimumRemoteAccessClientVersion(connection),
           !AirDeskAppVersion.isVersion(message.clientVersion, atLeast: minimumRemoteAccessClientVersion) {
            let status = PairingStatusMessage(
                paired: false,
                message: "Update the AirDesk iOS app to version \(minimumRemoteAccessClientVersion) or later before using Remote Access."
            )
            AirDeskDiagnostics.shared.record(
                "Rejected Remote Access client \(message.clientName) version \(message.clientVersion); requires \(minimumRemoteAccessClientVersion)+"
            )
            sendPairingStatus(status, to: connection)
            return false
        }

        let status = pairingManager?.authorize(message)
            ?? PairingStatusMessage(paired: true, message: "Paired")
        sendPairingStatus(status, to: connection)
        guard status.paired else { return false }
        authorizedConnections.insert(ObjectIdentifier(connection))
        notifyAuthorizedClientCount()
        return true
    }

    private func requiresMinimumRemoteAccessClientVersion(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "localhost"
            || value == "::1"
            || value == "0:0:0:0:0:0:0:1"
            || value == "127.0.0.1"
            || value.hasPrefix("127.")
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

    private func sendBinary(_ data: Data, to connection: NWConnection) {
        guard isAuthorized(connection) else { return }
        let id = ObjectIdentifier(connection)
        pendingSendCount[id, default: 0] += 1
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        connection.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed({ [weak self] _ in
            self?.serverQueue.async {
                let count = self?.pendingSendCount[id, default: 1] ?? 1
                let newCount = max(0, count - 1)
                self?.pendingSendCount[id] = newCount
                if newCount <= 1 {
                    self?.requestRecoveryKeyframesIfNeeded(for: id)
                }
            }
        }))
    }

    private func clearRecoveryState(for connectionID: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        awaitingKeyframes = awaitingKeyframes.filter { $0.connectionID != connectionID }
        requestedRecoveryKeyframes = requestedRecoveryKeyframes.filter { $0.connectionID != connectionID }
    }

    private func requestRecoveryKeyframesIfNeeded(for connectionID: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(serverQueue))
        let pendingDisplays = awaitingKeyframes
            .filter { $0.connectionID == connectionID && !requestedRecoveryKeyframes.contains($0) }
            .map(\.displayIndex)
        guard !pendingDisplays.isEmpty else { return }
        for displayIndex in pendingDisplays {
            let key = ConnectionDisplayKey(connectionID: connectionID, displayIndex: displayIndex)
            requestedRecoveryKeyframes.insert(key)
            encoder?.captureAndEncodeImmediate(displayIndex: displayIndex, forceKeyframe: true)
        }
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
                let recoveryKey = ConnectionDisplayKey(connectionID: id, displayIndex: displayIndex)
                if self.awaitingKeyframes.contains(recoveryKey) {
                    if isKeyframe {
                        let pending = self.pendingSendCount[id, default: 0]
                        if pending <= 1 {
                            self.awaitingKeyframes.remove(recoveryKey)
                            self.requestedRecoveryKeyframes.remove(recoveryKey)
                            self.sendBinary(frame, to: conn)
                        } else {
                            self.requestedRecoveryKeyframes.remove(recoveryKey)
                        }
                    }
                    continue
                }

                let pending = self.pendingSendCount[id, default: 0]
                if pending < 3 {
                    self.sendBinary(frame, to: conn)
                } else {
                    self.awaitingKeyframes.insert(recoveryKey)
                }
            }
        }
    }
}
