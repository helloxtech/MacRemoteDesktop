import Foundation
import QuartzCore
import UIKit
import AirDeskProtocol

class WebSocketClient: NSObject {

    private let host: String
    private let port: Int
    private let endpointURL: URL?
    private let pairingCode: String?
    private let clientID: String
    private let stateQueue = DispatchQueue(label: "airdesk.websocket.client")

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempts = 0
    private var isReconnecting = false
    private var isIntentionallyClosed = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectTimeoutWork: DispatchWorkItem?
    private var connectionGeneration = 0
    private var connectionProgress = WebSocketConnectionProgress()
    private var hasEverCompletedConnection = false
    private var hasSentConnectMessage = false
    private var requiresUserInitiatedReconnect = false
    private var lastLatencyCallbackValue: Int = -1
    private var lastLatencyCallbackTime: CFAbsoluteTime = 0
    private let latencyCallbackInterval: CFAbsoluteTime = 0.25

    // Liveness heartbeat. The Mac broadcasts permission_status every ~3s to every
    // authorized client, so a healthy connection always has inbound traffic even
    // when the desktop is static. If nothing arrives for staleTimeout we treat the
    // socket as half-open (common after the app is backgrounded) and force a
    // reconnect instead of leaving the user staring at a frozen/black canvas.
    private var lastInboundAt: CFAbsoluteTime = 0
    private var heartbeatTimer: DispatchSourceTimer?
    private let heartbeatCheckInterval: TimeInterval = 3.0
    private var staleTimeout: TimeInterval { endpointURL == nil ? 8.0 : 14.0 }

    var onMonitorsReceived: (([MonitorInfo]) -> Void)?
    // timestampMs added so AppState can compute latency
    var onVideoFrame: ((Data, Int, Bool, UInt32, Int) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onReconnectScheduled: ((Int, TimeInterval, Bool) -> Void)?
    var onClipboardChanged: ((String) -> Void)?
    var onLatencyUpdate: ((Int) -> Void)?
    var onLockStatusChanged: ((Bool, String) -> Void)?
    var onPermissionStatusChanged: ((PermissionStatusMessage) -> Void)?
    var onPairingStatusChanged: ((PairingStatusMessage) -> Void)?

    init(host: String, port: Int, pairingCode: String?) {
        self.host = host
        self.port = port
        self.endpointURL = nil
        self.pairingCode = pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientID = AirDeskClientIdentity.currentID
        super.init()
    }

    init(url: URL, pairingCode: String?) {
        self.host = url.host ?? url.absoluteString
        self.port = url.port ?? (url.scheme == "ws" ? 80 : 443)
        self.endpointURL = url
        self.pairingCode = pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientID = AirDeskClientIdentity.currentID
        super.init()
    }

    func connect() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isIntentionallyClosed = false
            self.startHeartbeatOnQueue()
            self.connectAttemptOnQueue(resetRetryCount: true)
        }
    }

    func disconnect() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.stopHeartbeatOnQueue()
            self.connectTimeoutWork?.cancel()
            self.connectTimeoutWork = nil
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.connectionGeneration += 1
            self.isIntentionallyClosed = true
            self.isReconnecting = false
            self.reconnectAttempts = self.maxReconnectAttempts
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.session?.invalidateAndCancel()
            self.task = nil
            self.session = nil
        }
    }

    /// Immediately checks whether the established connection has gone stale.
    /// Called when the app returns to the foreground, where iOS may have quietly
    /// torn down the socket without delivering a close callback.
    func checkConnectionHealthNow() {
        stateQueue.async { [weak self] in
            self?.checkHeartbeatOnQueue()
        }
    }

    private func startHeartbeatOnQueue() {
        stopHeartbeatOnQueue()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + heartbeatCheckInterval, repeating: heartbeatCheckInterval)
        timer.setEventHandler { [weak self] in
            self?.checkHeartbeatOnQueue()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeatOnQueue() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func checkHeartbeatOnQueue() {
        guard !isIntentionallyClosed, !isReconnecting else { return }
        // Only police sessions that have actually completed a handshake — a slow
        // first connect is handled by connectTimeoutWork, not the heartbeat.
        guard hasEverCompletedConnection, task != nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastInboundAt > 0, now - lastInboundAt > staleTimeout else { return }
        AirDeskDiagnostics.shared.record(String(format: "Connection stale (%.1fs without data); forcing reconnect", now - lastInboundAt))
        // Tear down the dead task and route through the normal reconnect path.
        task?.cancel(with: .abnormalClosure, reason: nil)
        handleDisconnectOnQueue(URLError(.timedOut))
    }

    func requestStream(displayIndex: Int) {
        stateQueue.async { [weak self] in
            self?.sendJSONOnQueue(RequestStreamMessage(displayIndex: displayIndex))
        }
    }

    func sendMouseMessage(_ msg: MouseMessage) {
        stateQueue.async { [weak self] in self?.sendJSONOnQueue(msg) }
    }

    func sendKeyboardMessage(_ msg: KeyboardMessage) {
        stateQueue.async { [weak self] in self?.sendJSONOnQueue(msg) }
    }

    func sendClipboard(_ text: String) {
        stateQueue.async { [weak self] in
            self?.sendJSONOnQueue(ClipboardMessage(type: "clipboard_push", content: text))
        }
    }

    func sendSystemAction(_ action: String) {
        stateQueue.async { [weak self] in
            self?.sendJSONOnQueue(SystemActionMessage(action: action))
        }
    }

    private func connectAttemptOnQueue(resetRetryCount: Bool) {
        if resetRetryCount {
            reconnectAttempts = 0
            hasEverCompletedConnection = false
        }
        connectionGeneration += 1
        let generation = connectionGeneration
        hasSentConnectMessage = false
        requiresUserInitiatedReconnect = false
        // Seed the heartbeat clock so a fresh attempt gets a full grace period
        // before the staleness check can fire.
        lastInboundAt = CFAbsoluteTimeGetCurrent()
        connectionProgress = WebSocketConnectionProgress()

        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil

        guard let url = websocketURL() else {
            NSLog("[AirDesk] Invalid WebSocket URL for %@", displayAddress)
            handleDisconnectOnQueue(URLError(.badURL), generation: generation)
            return
        }

        let config = URLSessionConfiguration.default
        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let newTask = newSession.webSocketTask(with: url)
        AirDeskDiagnostics.shared.record("Opening WebSocket to \(url.absoluteString)")
        session = newSession
        task = newTask

        newTask.resume()
        startReceivingOnQueue(generation: generation, task: newTask)

        let timeout = DispatchWorkItem { [weak self] in
            self?.handleDisconnectOnQueue(URLError(.timedOut), generation: generation)
        }
        connectTimeoutWork = timeout
        stateQueue.asyncAfter(deadline: .now() + connectTimeoutInterval, execute: timeout)
    }

    private func sendConnectMessageOnQueue() {
        guard !hasSentConnectMessage else { return }
        let nonce = UUID().uuidString
        let proof = AirDeskClientIdentity.authProof(clientID: clientID, nonce: nonce)
        hasSentConnectMessage = true
        AirDeskDiagnostics.shared.record("Sending connect message to \(displayAddress)")
        sendJSONOnQueue(ConnectMessage(
            clientName: UIDevice.current.name,
            clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0",
            clientID: clientID,
            pairingCode: normalizedPairingCode(),
            clientNonce: proof == nil ? nil : nonce,
            authProof: proof
        ))
    }

    private func normalizedPairingCode() -> String? {
        guard let pairingCode, !pairingCode.isEmpty else { return nil }
        return pairingCode
    }

    private func websocketURL() -> URL? {
        if let endpointURL {
            return endpointURL
        }
        let needsIPv6Brackets = host.contains(":") && !host.hasPrefix("[") && !host.hasSuffix("]")
        let formattedHost = needsIPv6Brackets ? "[\(host)]" : host
        return URL(string: "ws://\(formattedHost):\(port)")
    }

    private var displayAddress: String {
        endpointURL?.absoluteString ?? "\(host):\(port)"
    }

    private func sendJSONOnQueue<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return }
        guard let task else {
            NSLog("[AirDesk] sendJSON: task is nil, message dropped")
            return
        }
        task.send(.string(text)) { error in
            if let error { NSLog("[AirDesk] WebSocketClient send error: \(error)") }
        }
    }

    private func startReceivingOnQueue(generation: Int, task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.stateQueue.async {
                guard generation == self.connectionGeneration, task === self.task else { return }
                switch result {
                case .success(let message):
                    self.handleMessageOnQueue(message)
                    self.startReceivingOnQueue(generation: generation, task: task)
                case .failure(let error):
                    self.handleDisconnectOnQueue(error, generation: generation)
                }
            }
        }
    }

    private func handleMessageOnQueue(_ message: URLSessionWebSocketTask.Message) {
        // Any inbound traffic proves the socket is alive (the Mac sends a
        // permission_status heartbeat every few seconds even on a static screen).
        lastInboundAt = CFAbsoluteTimeGetCurrent()
        switch message {
        case .string(let text): handleTextMessageOnQueue(text)
        case .data(let data):   handleBinaryMessageOnQueue(data)
        @unknown default:       break
        }
    }

    private func handleTextMessageOnQueue(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "screen_info":
            guard let msg = try? JSONDecoder().decode(ScreenInfoMessage.self, from: data) else {
                AirDeskDiagnostics.shared.record("Ignored malformed screen info message")
                return
            }
            let progressAction = connectionProgress.screenInfoReceived(monitorCount: msg.monitors.count)
            guard progressAction == .connected else {
                AirDeskDiagnostics.shared.record("Received empty screen info; waiting for Mac display metadata")
                return
            }
            hasEverCompletedConnection = true
            connectTimeoutWork?.cancel()
            connectTimeoutWork = nil
            reconnectAttempts = 0
            onMonitorsReceived?(msg.monitors)
        case "clipboard_changed":
            if let msg = try? JSONDecoder().decode(ClipboardMessage.self, from: data) {
                onClipboardChanged?(msg.content)
            }
        case "lock_status":
            if let msg = try? JSONDecoder().decode(LockStatusMessage.self, from: data) {
                onLockStatusChanged?(msg.isLocked, msg.message)
            }
        case "permission_status":
            if let msg = try? JSONDecoder().decode(PermissionStatusMessage.self, from: data) {
                onPermissionStatusChanged?(msg)
            }
        case "pairing_status":
            if let msg = try? JSONDecoder().decode(PairingStatusMessage.self, from: data) {
                let progressAction = connectionProgress.pairingStatusReceived(paired: msg.paired)
                if progressAction == .waitingForPairingCode {
                    connectTimeoutWork?.cancel()
                    connectTimeoutWork = nil
                }
                if msg.paired, let token = msg.authToken, !token.isEmpty {
                    AirDeskClientIdentity.storeSecret(token)
                } else if !msg.paired {
                    requiresUserInitiatedReconnect = true
                    AirDeskClientIdentity.clearSecret()
                }
                onPairingStatusChanged?(msg)
            }
        default:
            break
        }
    }

    private func handleBinaryMessageOnQueue(_ data: Data) {
        guard data.count > 7, data[0] == 0x01 else { return }

        let displayIndex = Int(data[1])
        let tsMs: UInt32 = data.withUnsafeBytes { bytes in
            let ptr = bytes.baseAddress!.advanced(by: 2).assumingMemoryBound(to: UInt8.self)
            return UInt32(ptr[0]) << 24 | UInt32(ptr[1]) << 16 | UInt32(ptr[2]) << 8 | UInt32(ptr[3])
        }
        let isKeyframe = (data[6] & 0x01) != 0
        let nowMs = UInt32(CACurrentMediaTime() * 1000) & 0xFFFFFFFF
        let latency = Int(nowMs &- tsMs)
        if shouldPublishLatencyOnQueue(latency) { onLatencyUpdate?(latency) }

        onVideoFrame?(data, displayIndex, isKeyframe, tsMs, 7)
    }

    private func shouldPublishLatencyOnQueue(_ latency: Int) -> Bool {
        guard latency >= 0 && latency < 5000 else { return false }
        guard latency != lastLatencyCallbackValue else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastLatencyCallbackValue < 0 || now - lastLatencyCallbackTime >= latencyCallbackInterval else { return false }
        lastLatencyCallbackValue = latency
        lastLatencyCallbackTime = now
        return true
    }

    private func handleDisconnectOnQueue(_ error: Error?, generation: Int? = nil) {
        if let generation, generation != connectionGeneration { return }
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        hasSentConnectMessage = false
        guard !isIntentionallyClosed else { return }
        guard !requiresUserInitiatedReconnect else { return }
        guard !isReconnecting else { return }
        if attemptReconnectOnQueue() { return }
        onDisconnect?(error)
    }

    @discardableResult
    private func attemptReconnectOnQueue() -> Bool {
        guard !isIntentionallyClosed else { return false }
        guard reconnectAttempts < maxReconnectAttempts, !isReconnecting else { return false }
        isReconnecting = true
        reconnectAttempts += 1
        let delay = reconnectDelay(for: reconnectAttempts)
        let generation = connectionGeneration
        onReconnectScheduled?(reconnectAttempts, delay, hasEverCompletedConnection)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isIntentionallyClosed else { return }
            guard generation == self.connectionGeneration else { return }
            self.isReconnecting = false
            self.connectAttemptOnQueue(resetRetryCount: false)
        }
        reconnectWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return true
    }

    private var connectTimeoutInterval: TimeInterval {
        endpointURL == nil ? 10 : 20
    }

    private var maxReconnectAttempts: Int {
        endpointURL == nil ? 5 : 20
    }

    private func reconnectDelay(for attempt: Int) -> TimeInterval {
        if endpointURL == nil {
            return Double(attempt) * 2.0
        }
        return min(Double(attempt), 8.0)
    }
}

enum AirDeskClientIdentity {
    private static let idKey = "airdesk.client.identity"
    private static let secretKey = "airdesk.client.authSecret"

    static var currentID: String {
        if let existing = UserDefaults.standard.string(forKey: idKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    static var hasStoredSecret: Bool {
        guard let secret = UserDefaults.standard.string(forKey: secretKey) else { return false }
        return !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func authProof(clientID: String, nonce: String) -> String? {
        guard let secret = UserDefaults.standard.string(forKey: secretKey), !secret.isEmpty else { return nil }
        return AirDeskAuthProof.make(clientID: clientID, nonce: nonce, secret: secret)
    }

    static func storeSecret(_ secret: String) {
        UserDefaults.standard.set(secret, forKey: secretKey)
    }

    static func clearSecret() {
        UserDefaults.standard.removeObject(forKey: secretKey)
    }
}

extension WebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        stateQueue.async { [weak self] in
            guard let self, webSocketTask === self.task else { return }
            self.isReconnecting = false
            self.connectionProgress.webSocketDidOpen()
            AirDeskDiagnostics.shared.record("WebSocket opened to \(self.displayAddress)")
            self.sendConnectMessageOnQueue()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        stateQueue.async { [weak self] in
            guard let self, webSocketTask === self.task else { return }
            AirDeskDiagnostics.shared.record("WebSocket closed with code \(closeCode.rawValue)")
            self.handleDisconnectOnQueue(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateQueue.async { [weak self] in
            guard let self, task === self.task else { return }
            if let error {
                AirDeskDiagnostics.shared.record("WebSocket task completed with error: \(error.localizedDescription)")
                self.handleDisconnectOnQueue(error)
            }
        }
    }
}
